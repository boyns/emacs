;;; treesit.el --- tree-sitter utilities -*- lexical-binding: t -*-

;; Copyright (C) 2021-2024 Free Software Foundation, Inc.

;; Maintainer: 付禹安 (Yuan Fu) <casouri@gmail.com>
;; Keywords: treesit, tree-sitter, languages
;; Package: emacs

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This file is the Lisp counterpart of treesit.c.  Together they
;; provide tree-sitter integration for Emacs.  This file contains
;; convenient functions that are more idiomatic and flexible than the
;; exposed C API of tree-sitter.  It also contains frameworks for
;; integrating tree-sitter with font-lock, indentation, activating and
;; deactivating tree-sitter, debugging tree-sitter, etc.

;;; Code:

(eval-when-compile (require 'subr-x)) ; For `string-join'.
(require 'cl-lib)
(require 'font-lock)
(require 'seq)

;;; Function declarations

(declare-function treesit-language-available-p "treesit.c")
(declare-function treesit-language-version "treesit.c")

(declare-function treesit-parser-p "treesit.c")
(declare-function treesit-node-p "treesit.c")
(declare-function treesit-compiled-query-p "treesit.c")
(declare-function treesit-query-p "treesit.c")
(declare-function treesit-query-language "treesit.c")

(declare-function treesit-node-parser "treesit.c")

(declare-function treesit-parser-create "treesit.c")
(declare-function treesit-parser-delete "treesit.c")
(declare-function treesit-parser-list "treesit.c")
(declare-function treesit-parser-buffer "treesit.c")
(declare-function treesit-parser-language "treesit.c")
(declare-function treesit-parser-tag "treesit.c")

(declare-function treesit-parser-root-node "treesit.c")

(declare-function treesit-parser-set-included-ranges "treesit.c")
(declare-function treesit-parser-included-ranges "treesit.c")
(declare-function treesit-parser-changed-ranges "treesit.c")
(declare-function treesit-parser-add-notifier "treesit.c")

(declare-function treesit-node-type "treesit.c")
(declare-function treesit-node-start "treesit.c")
(declare-function treesit-node-end "treesit.c")
(declare-function treesit-node-string "treesit.c")
(declare-function treesit-node-parent "treesit.c")
(declare-function treesit-node-child "treesit.c")
(declare-function treesit-node-check "treesit.c")
(declare-function treesit-node-field-name-for-child "treesit.c")
(declare-function treesit-node-child-count "treesit.c")
(declare-function treesit-node-child-by-field-name "treesit.c")
(declare-function treesit-node-next-sibling "treesit.c")
(declare-function treesit-node-prev-sibling "treesit.c")
(declare-function treesit-node-first-child-for-pos "treesit.c")
(declare-function treesit-node-descendant-for-range "treesit.c")
(declare-function treesit-node-eq "treesit.c")

(declare-function treesit-pattern-expand "treesit.c")
(declare-function treesit-query-expand "treesit.c")
(declare-function treesit-query-compile "treesit.c")
(declare-function treesit-query-capture "treesit.c")

(declare-function treesit-search-subtree "treesit.c")
(declare-function treesit-search-forward "treesit.c")
(declare-function treesit-induce-sparse-tree "treesit.c")
(declare-function treesit-subtree-stat "treesit.c")
(declare-function treesit-node-match-p "treesit.c")

(declare-function treesit-available-p "treesit.c")

(defvar treesit-thing-settings)

;;; Custom options

;; Tree-sitter always appear as treesit in symbols.
(defgroup treesit nil
  "Incremental parser.
It is used to enhance major mode features like font-lock,
indent, imenu, etc."
  :group 'tools
  :version "29.1")

(defcustom treesit-max-buffer-size
  (let ((mb (* 1024 1024)))
    ;; 40MB for 64-bit systems, 15 for 32-bit.
    (if (or (< most-positive-fixnum (* 2.0 1024 mb))
            ;; 32-bit system with wide ints.
            (string-search "--with-wide-int" system-configuration-options))
        (* 15 mb)
      (* 40 mb)))
  "Maximum buffer size (in bytes) for enabling tree-sitter parsing.

A typical tree-sitter parser needs 10 times as much memory as the
buffer it parses.  Also, the tree-sitter library has a hard limit
of max unsigned 32-bit value for byte offsets into buffer text."
  :type 'integer
  :version "29.1")

;;; Parser API supplement

(defvar-local treesit-language-at-point-function nil
  "A function that returns the language at point.
This is used by `treesit-language-at', which is used by various
functions to determine which parser to use at point.

The function is called with one argument, the position of point.

In general, this function should call `treesit-node-at' with an
explicit language (usually the host language), and determine the
language at point using the type of the returned node.

DO NOT derive the language at point from parser ranges.  It's
cumbersome and can't deal with some edge cases.")

(defun treesit-language-at (position)
  "Return the language at POSITION.

This function assumes that parser ranges are up-to-date.  It
returns the return value of `treesit-language-at-point-function'
if it's non-nil, otherwise it returns the language of the first
parser in `treesit-parser-list', or nil if there is no parser.

In a multi-language buffer, make sure
`treesit-language-at-point-function' is implemented!  Otherwise
`treesit-language-at' wouldn't return the correct result."
  (if treesit-language-at-point-function
      (funcall treesit-language-at-point-function position)
    (when-let ((parser (car (treesit-parser-list))))
      (treesit-parser-language parser))))

;;; Node API supplement

(define-error 'treesit-no-parser "No available parser for this buffer"
              'treesit-error)

(defun treesit-node-buffer (node)
  "Return the buffer in which NODE belongs."
  (treesit-parser-buffer
   (treesit-node-parser node)))

(defun treesit-node-language (node)
  "Return the language symbol that NODE's parser uses."
  (treesit-parser-language
   (treesit-node-parser node)))

(defun treesit-node-at (pos &optional parser-or-lang named)
  "Return the leaf node at position POS.

A leaf node is a node that doesn't have any child nodes.

The returned node's span covers POS: the node's beginning is before
or at POS, and the node's end is after POS.

If no such node exists, but there's a leaf node which ends at POS,
return that node.

Otherwise (e.g., when POS is on whitespace between two leaf
nodes), return the first leaf node after POS.

If there is no leaf node after POS, return the first leaf node
before POS.

Return nil if no leaf node can be returned.  If NAMED is non-nil,
only look for named nodes.

If PARSER-OR-LANG is a parser, use that parser; if PARSER-OR-LANG
is a language, find the first parser for that language in the
current buffer, or create one if none exists; If PARSER-OR-LANG
is nil, try to guess the language at POS using `treesit-language-at'.

If there's a local parser at POS, the local parser takes priority
unless PARSER-OR-LANG is a parser, or PARSER-OR-LANG is a
language and doesn't match the language of the local parser."
  (let* ((root (if (treesit-parser-p parser-or-lang)
                   (treesit-parser-root-node parser-or-lang)
                 (or (when-let ((parser
                                 (car (treesit-local-parsers-at
                                       pos parser-or-lang))))
                       (treesit-parser-root-node parser))
                     (treesit-buffer-root-node
                      (or parser-or-lang
                          (treesit-language-at pos))))))
         (node root)
         (node-before root)
         (pos-1 (max (1- pos) (point-min)))
         next)
    (when node
      ;; This is very fast so no need for C implementation.
      (while (setq next (treesit-node-first-child-for-pos
                         node pos named))
        (setq node next))
      ;; If POS is at the end of buffer, after all the text, we will
      ;; end up with NODE = root node.  Instead of returning nil,
      ;; return the last leaf node in the tree for convenience.
      (if (treesit-node-eq node root)
          (progn
            (while (setq next (treesit-node-child node -1 named))
              (setq node next))
            node)
        ;; Normal case, where we found a node.
        (if (<= (treesit-node-start node) pos)
            node
          ;; So the node we found is completely after POS, try to find
          ;; a node whose end equals to POS.
          (while (setq next (treesit-node-first-child-for-pos
                             node-before pos-1 named))
            (setq node-before next))
          (if (eq (treesit-node-end node-before) pos)
              node-before
            node))))))

(defun treesit-node-on (beg end &optional parser-or-lang named)
  "Return the smallest node covering BEG to END.

BEWARE!  Calling this function on an empty line that is not
inside any top-level construct (function definition, etc.) most
probably will give you the root node, because the root node is
the smallest node that covers that empty line.  You probably want
to use `treesit-node-at' instead.

Return nil if none was found.  If NAMED is non-nil, only look for
named node.

If PARSER-OR-LANG is a parser, use that parser; if PARSER-OR-LANG
is a language, find the first parser for that language in the
current buffer, or create one if none exists; If PARSER-OR-LANG
is nil, try to guess the language at BEG using `treesit-language-at'.

If there's a local parser between BEG and END, try to use that
parser first."
  (let* ((lang-at-point (treesit-language-at beg))
         (root (if (treesit-parser-p parser-or-lang)
                   (treesit-parser-root-node parser-or-lang)
                 (or (when-let ((parser
                                 (car (treesit-local-parsers-on
                                       beg end (or parser-or-lang
                                                   lang-at-point)))))
                       (treesit-parser-root-node parser))
                     (treesit-buffer-root-node
                      (or parser-or-lang lang-at-point))))))
    (treesit-node-descendant-for-range root beg (or end beg) named)))

(defun treesit-node-top-level (node &optional pred include-node)
  "Return the top-level equivalent of NODE.

Specifically, return the highest parent of NODE that has the same
type as it.  If no such parent exists, return nil.

If PRED is non-nil, match each parent's type with PRED rather
than using NODE's type.  PRED can also be a predicate function,
and more.  See `treesit-thing-settings' for details.

If INCLUDE-NODE is non-nil, return NODE if it satisfies PRED."
  (let ((pred (or pred (rx bos (literal (treesit-node-type node)) eos)))
        (result nil))
    (cl-loop for cursor = (if include-node node
                            (treesit-node-parent node))
             then (treesit-node-parent cursor)
             while cursor
             if (treesit-node-match-p cursor pred t)
             do (setq result cursor))
    result))

(defun treesit-buffer-root-node (&optional language tag)
  "Return the root node of the current buffer.

Use the first parser in the parser list if LANGUAGE is omitted.

If LANGUAGE is non-nil, use the first parser for LANGUAGE with
TAG in the parser list, or create one if none exists.  TAG
defaults to nil."
  (if-let ((parser
            (if language
                (treesit-parser-create language nil nil tag)
              (or (car (treesit-parser-list))
                  (signal 'treesit-no-parser (list (current-buffer)))))))
      (treesit-parser-root-node parser)))

(defun treesit-filter-child (node pred &optional named)
  "Return children of NODE that satisfies predicate PRED.
PRED is a function that takes one argument, the child node.
If optional argument NAMED is non-nil, only search for named
node."
  (let ((child (treesit-node-child node 0 named))
        result)
    (while child
      (when (funcall pred child)
        (push child result))
      (setq child (treesit-node-next-sibling child named)))
    (reverse result)))

(defun treesit-node-text (node &optional no-property)
  "Return the buffer (or string) content corresponding to NODE.
If optional argument NO-PROPERTY is non-nil, remove text
properties."
  (when node
    (with-current-buffer (treesit-node-buffer node)
      (if no-property
          (buffer-substring-no-properties
           (treesit-node-start node)
           (treesit-node-end node))
        (buffer-substring
         (treesit-node-start node)
         (treesit-node-end node))))))

(defun treesit-parent-until (node pred &optional include-node)
  "Return the closest parent of NODE that satisfies PRED.

This function successively examines the parent of NODE, then
the parent of the parent, etc., until it finds the first
ancestor node which satisfies the predicate PRED; then it
returns that ancestor node.  It returns nil if no ancestor
node was found that satisfies PRED.

PRED can be a predicate function, a regexp matching node type,
and more; see docstring of `treesit-thing-settings'.

If INCLUDE-NODE is non-nil, return NODE if it satisfies PRED."
  (let ((node (if include-node node
                (treesit-node-parent node))))
    (while (and node (not (treesit-node-match-p node pred)))
      (setq node (treesit-node-parent node)))
    node))

(defun treesit-parent-while (node pred)
  "Return the furthest parent of NODE (including NODE) that satisfies PRED.

This function successively examines NODE, the parent of NODE,
then the parent of the parent, etc., until it finds a node which
no longer satisfies the predicate PRED; it returns the last
examined node that satisfies PRED.  If no node satisfies PRED, it
returns nil.

PRED can be a predicate function, a regexp matching node type,
and more; see docstring of `treesit-thing-settings'."
  (let ((last nil))
    (while (and node (treesit-node-match-p node pred))
      (setq last node
            node (treesit-node-parent node)))
    last))

(defun treesit-node-children (node &optional named)
  "Return a list of NODE's children.
If NAMED is non-nil, collect named child only."
  (mapcar (lambda (idx)
            (treesit-node-child node idx named))
          (number-sequence
           0 (1- (treesit-node-child-count node named)))))

(defun treesit-node-index (node &optional named)
  "Return the index of NODE in its parent.
If NAMED is non-nil, count named child only."
  (let ((count 0))
    (while (setq node (treesit-node-prev-sibling node named))
      (cl-incf count))
    count))

(defun treesit-node-field-name (node)
  "Return the field name of NODE as a child of its parent."
  (when-let ((parent (treesit-node-parent node))
             (idx (treesit-node-index node)))
    (treesit-node-field-name-for-child parent idx)))

(defun treesit-node-get (node instructions)
  "Get things from NODE by INSTRUCTIONS.

This is a convenience function that chains together multiple node
accessor functions together.  For example, to get NODE's parent's
next sibling's second child's text, call

   (treesit-node-get node
     \\='((parent 1)
       (sibling 1 nil)
       (child 1 nil)
       (text nil)))

INSTRUCTION is a list of INSTRUCTIONs of the form (FN ARG...).
The following FN's are supported:

\(child IDX NAMED)    Get the IDX'th child
\(parent N)           Go to parent N times
\(field-name)         Get the field name of the current node
\(type)               Get the type of the current node
\(text NO-PROPERTY)   Get the text of the current node
\(children NAMED)     Get a list of children
\(sibling STEP NAMED) Get the nth prev/next sibling, negative STEP
                     means prev sibling, positive means next

Note that arguments like NAMED and NO-PROPERTY can't be omitted,
unlike in their original functions."
  (declare (indent 1))
  (while (and node instructions)
    (pcase (pop instructions)
      ('(field-name) (setq node (treesit-node-field-name node)))
      ('(type) (setq node (treesit-node-type node)))
      (`(child ,idx ,named) (setq node (treesit-node-child node idx named)))
      (`(parent ,n) (dotimes (_ n)
                      (setq node (treesit-node-parent node))))
      (`(text ,no-property) (setq node (treesit-node-text node no-property)))
      (`(children ,named) (setq node (treesit-node-children node named)))
      (`(sibling ,step ,named)
       (dotimes (_ (abs step))
         (setq node (if (> step 0)
                        (treesit-node-next-sibling node named)
                      (treesit-node-prev-sibling node named)))))))
  node)

(defun treesit-node-enclosed-p (smaller larger &optional strict)
  "Return non-nil if SMALLER is enclosed in LARGER.
SMALLER and LARGER can be either (BEG . END) or a node.

Return non-nil if LARGER's start <= SMALLER's start and LARGER's
end <= SMALLER's end.

If STRICT is t, compare with < rather than <=.

If STRICT is \\='partial, consider LARGER encloses SMALLER when
at least one side is strictly enclosing."
  (unless (and (or (consp larger) (treesit-node-p larger))
               (or (consp smaller) (treesit-node-p smaller)))
    (signal 'wrong-type-argument '((or cons treesit-node))))
  (let ((larger-start (if (consp larger)
                          (car larger)
                        (treesit-node-start larger)))
        (larger-end (if (consp larger)
                        (cdr larger)
                      (treesit-node-end larger)))
        (smaller-start (if (consp smaller)
                           (car smaller)
                         (treesit-node-start smaller)))
        (smaller-end (if (consp smaller)
                         (cdr smaller)
                       (treesit-node-end smaller))))
    (pcase strict
      ('t (and (< larger-start smaller-start)
               (< smaller-end larger-end)))
      ('partial (and (or (not (eq larger-start smaller-start))
                         (not (eq larger-end smaller-end)))
                     (<= larger-start smaller-start
                         smaller-end larger-end)))
      (_ (<= larger-start smaller-start smaller-end larger-end)))))

;;; Query API supplement

(defun treesit-query-string (string query language)
  "Query STRING with QUERY in LANGUAGE.
See `treesit-query-capture' for QUERY."
  (with-temp-buffer
    (insert string)
    (let ((parser (treesit-parser-create language)))
      (treesit-query-capture
       (treesit-parser-root-node parser)
       query))))

(defun treesit-query-range (node query &optional beg end offset)
  "Query the current buffer and return ranges of captured nodes.

QUERY, NODE, BEG, END are the same as in `treesit-query-capture'.
This function returns a list of (START . END), where START and
END specifics the range of each captured node.  OFFSET is an
optional pair of numbers (START-OFFSET . END-OFFSET).  The
respective offset values are added to each (START . END) range
being returned.  Capture names generally don't matter, but names
that starts with an underscore are ignored."
  (let ((offset-left (or (car offset) 0))
        (offset-right (or (cdr offset) 0)))
    (cl-loop for capture
             in (treesit-query-capture node query beg end)
             for name = (car capture)
             for node = (cdr capture)
             if (not (string-prefix-p "_" (symbol-name name)))
             collect (cons (+ (treesit-node-start node) offset-left)
                           (+ (treesit-node-end node) offset-right)))))

;;; Range API supplement

(defvar-local treesit-range-settings nil
  "A list of range settings.

Each element of the list is of the form (QUERY LANGUAGE LOCAL-P
OFFSET).  When updating the range of each parser in the buffer,
`treesit-update-ranges' queries each QUERY, and sets LANGUAGE's
range to the range spanned by captured nodes.  QUERY must be a
compiled query.  If LOCAL-P is t, give each range a separate
local parser rather than using a single parser for all the
ranges.  If OFFSET is non-nil, it should be a cons of
numbers (START-OFFSET . END-OFFSET), where the start and end
offset are added to each queried range to get the result ranges.

Capture names generally don't matter, but names that starts with
an underscore are ignored.

QUERY can also be a function, in which case it is called with 2
arguments, START and END.  It should ensure parsers' ranges are
correct in the region between START and END.

The exact form of each setting is considered internal and subject
to change.  Use `treesit-range-rules' to set this variable.")

(defun treesit-range-rules (&rest query-specs)
  "Produce settings for `treesit-range-settings'.

QUERY-SPECS are a series of QUERY-SPECs, where each QUERY-SPEC is
a QUERY preceded by zero or more pairs of :KEYWORD and VALUE,
like this:

    :KEYWORD VALUE... QUERY

Each QUERY is a tree-sitter query in either the string,
s-expression or compiled form.

Capture names generally don't matter, but names that starts with
an underscore are ignored.

For each QUERY, :KEYWORD and VALUE pairs add meta information to
it.  For example,

    (treesit-range-rules
     :embed \\='javascript
     :host \\='html
     :offset \\='(1 . -1)
     \\='((script_element (raw_text) @cap)))

The `:embed' keyword specifies the embedded language, and the
`:host' keyword specifies the host language.  They are used in
this way: Emacs queries QUERY in the host language's parser,
computes the ranges spanned by the captured nodes, and applies
these ranges to parsers for the embedded language.

If there's a `:local' keyword with value t, the range computed by
this QUERY is given a dedicated local parser.  Otherwise, the
range shares the same parser with other ranges.

If there's an `:offset' keyword with a pair of numbers, each
captured range is offset by those numbers.  For example, an
offset of (1 . -1) will update a captured range of (2 . 8) to
be (3 . 7).  This can be used to exclude things like surrounding
delimiters from being included in the range covered by an
embedded parser.

QUERY can also be a function that takes two arguments, START and
END.  If QUERY is a function, it doesn't need the :KEYWORD VALUE
pair preceding it.  This function should set the ranges for
parsers in the current buffer in the region between START and
END.  It is OK for this function to set ranges in a larger region
that encompasses the region between START and END."
  (let (host embed offset result local)
    (while query-specs
      (pcase (pop query-specs)
        (:local (when (eq t (pop query-specs))
                  (setq local t)))
        (:host (let ((host-lang (pop query-specs)))
                 (unless (symbolp host-lang)
                   (signal 'treesit-error (list "Value of :host option should be a symbol" host-lang)))
                 (setq host host-lang)))
        (:embed (let ((embed-lang (pop query-specs)))
                  (unless (symbolp embed-lang)
                    (signal 'treesit-error (list "Value of :embed option should be a symbol" embed-lang)))
                  (setq embed embed-lang)))
        (:offset (let ((range-offset (pop query-specs)))
                   (unless (and (consp range-offset)
                                (numberp (car range-offset))
                                (numberp (cdr range-offset)))
                     (signal 'treesit-error (list "Value of :offset option should be a pair of numbers" range-offset)))
                   (setq offset range-offset)))
        (query (if (functionp query)
                   (push (list query nil nil) result)
                 (when (null embed)
                   (signal 'treesit-error (list "Value of :embed option cannot be omitted")))
                 (when (null host)
                   (signal 'treesit-error (list "Value of :host option cannot be omitted")))
                 (push (list (treesit-query-compile host query)
                             embed local offset)
                       result))
               (setq host nil embed nil offset nil local nil))))
    (nreverse result)))

(defun treesit--merge-ranges (old-ranges new-ranges start end)
  "Merge OLD-RANGES and NEW-RANGES, discarding ranges between START and END.
OLD-RANGES and NEW-RANGES are lists of cons of the form (BEG . END).
When merging the two ranges, if a range in OLD-RANGES intersects with
another range in NEW-RANGES, discard the one in OLD-RANGES and
keep the one in NEW-RANGES.  Also discard any range in OLD-RANGES
that intersects the region marked by START and END.

Return the merged list of ranges."
  (let ((result nil))
    (while (and old-ranges new-ranges)
      (let ((new-beg (caar new-ranges))
            (new-end (cdar new-ranges))
            (old-beg (caar old-ranges))
            (old-end (cdar old-ranges)))
        (cond
         ;; Old range intersects with START-END, discard.
         ((and (< start old-end)
               (< old-beg end))
          (setq old-ranges (cdr old-ranges)))
         ;; New range and old range don't intersect, new comes
         ;; before, push new.
         ((<= new-end old-beg)
          (push (car new-ranges) result)
          (setq new-ranges (cdr new-ranges)))
         ;; New range and old range don't intersect, old comes
         ;; before, push old.
         ((<= old-end new-beg)
          (push (car old-ranges) result)
          (setq old-ranges (cdr old-ranges)))
         (t ;; New and old range intersect, discard old.
          (setq old-ranges (cdr old-ranges))))))
    (let ((left-over (or new-ranges old-ranges)))
      (dolist (range left-over)
        (push range result)))
    (nreverse result)))

(defun treesit--clip-ranges (ranges start end)
  "Clip RANGES in between START and END.
RANGES is a list of ranges of the form (BEG . END).  Ranges
outside of the region between START and END are thrown away, and
those inside are kept."
  (cl-loop for range in ranges
           if (<= start (car range) (cdr range) end)
           collect range))

(defun treesit-local-parsers-at (&optional pos language with-host)
  "Return all the local parsers at POS.

POS defaults to point.
Local parsers are those which only parse a limited region marked
by an overlay with non-nil `treesit-parser' property.
If LANGUAGE is non-nil, only return parsers for LANGUAGE.

If WITH-HOST is non-nil, return a list of (PARSER . HOST-PARSER)
instead.  HOST-PARSER is the host parser which created the local
PARSER."
  (let ((res nil))
    (dolist (ov (overlays-at (or pos (point))))
      (when-let ((parser (overlay-get ov 'treesit-parser))
                 (host-parser (overlay-get ov 'treesit-host-parser)))
        (when (or (null language)
                  (eq (treesit-parser-language parser)
                      language))
          (push (if with-host (cons parser host-parser) parser) res))))
    (nreverse res)))

(defun treesit-local-parsers-on (&optional beg end language with-host)
  "Return all the local parsers between BEG END.

BEG and END default to the beginning and end of the buffer's
accessible portion.
Local parsers are those which have an `embedded' tag, and only parse
a limited region marked by an overlay with a non-nil `treesit-parser'
property.  If LANGUAGE is non-nil, only return parsers for LANGUAGE.

If WITH-HOST is non-nil, return a list of (PARSER . HOST-PARSER)
instead.  HOST-PARSER is the host parser which created the local
PARSER."
  (let ((res nil))
    (dolist (ov (overlays-in (or beg (point-min)) (or end (point-max))))
      (when-let ((parser (overlay-get ov 'treesit-parser))
                 (host-parser (overlay-get ov 'treesit-host-parser)))
        (when (or (null language)
                  (eq (treesit-parser-language parser)
                      language))
          (push (if with-host (cons parser host-parser) parser) res))))
    (nreverse res)))

(defun treesit--cleanup-local-range-overlays (modified-tick beg end)
  "Cleanup overlays used to mark local parsers between BEG and END.

For every local parser overlay between BEG and END, if its
`treesit-parser-ov-timestamp' is smaller than MODIFIED-TICK, delete
it."
  (dolist (ov (overlays-in beg end))
    (when-let ((ov-timestamp
                (overlay-get ov 'treesit-parser-ov-timestamp)))
      (when (< ov-timestamp modified-tick)
        (when-let ((local-parser (overlay-get ov 'treesit-parser)))
          (treesit-parser-delete local-parser))
        (delete-overlay ov)))))

(defun treesit--update-ranges-local
    (query embedded-lang modified-tick &optional beg end)
  "Update range for local parsers between BEG and END.
Use QUERY to get the ranges, and make sure each range has a local
parser for EMBEDDED-LANG.

The local parser is stored in an overlay, in the `treesit-parser'
property, the host parser is stored in the `treesit-host-parser'
property.

When this function touches an overlay, it sets the
`treesit-parser-ov-timestamp' property of the overlay to
MODIFIED-TICK.  This will help Emacs garbage-collect overlays that
aren't in use anymore."
  ;; Update range.
  (let* ((host-lang (treesit-query-language query))
         (host-parser (treesit-parser-create host-lang))
         (ranges (treesit-query-range host-parser query beg end)))
    (pcase-dolist (`(,beg . ,end) ranges)
      (let ((has-parser nil))
        (setq
         has-parser
         (catch 'done
           (dolist (ov (overlays-in beg end) nil)
             ;; Update range of local parser.
             (when-let* ((embedded-parser (overlay-get ov 'treesit-parser))
                         (parser-lang (treesit-parser-language
                                       embedded-parser)))
               (when (eq parser-lang embedded-lang)
                 (treesit-parser-set-included-ranges
                  embedded-parser `((,beg . ,end)))
                 (move-overlay ov beg end)
                 (overlay-put ov 'treesit-parser-ov-timestamp
                              modified-tick)
                 (throw 'done t))))))
        ;; Create overlay and local parser.
        (when (not has-parser)
          (let ((embedded-parser (treesit-parser-create
                                  embedded-lang nil t 'embedded))
                (ov (make-overlay beg end nil nil t)))
            (overlay-put ov 'treesit-parser embedded-parser)
            (overlay-put ov 'treesit-host-parser host-parser)
            (overlay-put ov 'treesit-parser-ov-timestamp
                         modified-tick)
            (treesit-parser-set-included-ranges
             embedded-parser `((,beg . ,end)))))))))

(defun treesit-update-ranges (&optional beg end)
  "Update the ranges for each language in the current buffer.
If BEG and END are non-nil, only update parser ranges in that
region."
  (let ((modified-tick (buffer-chars-modified-tick))
        (beg (or beg (point-min)))
        (end (or end (point-max))))
    ;; When updating ranges, we want to avoid querying the whole buffer
    ;; which could be slow in very large buffers.  Instead, we only
    ;; query for nodes that intersect with the region between BEG and
    ;; END.  Also, we only update the ranges intersecting BEG and END;
    ;; outside of that region we inherit old ranges.
    (dolist (setting treesit-range-settings)
      (let ((query (nth 0 setting))
            (language (nth 1 setting))
            (local (nth 2 setting))
            (offset (nth 3 setting)))
        (cond
         ((functionp query) (funcall query beg end))
         (local
          (treesit--update-ranges-local
           query language modified-tick beg end))
         (t
          (let* ((host-lang (treesit-query-language query))
                 (parser (treesit-parser-create language))
                 (old-ranges (treesit-parser-included-ranges parser))
                 (new-ranges (treesit-query-range
                              host-lang query beg end offset))
                 (set-ranges (treesit--clip-ranges
                              (treesit--merge-ranges
                               old-ranges new-ranges beg end)
                              (point-min) (point-max))))
            (dolist (parser (treesit-parser-list nil language))
              (treesit-parser-set-included-ranges
               parser (or set-ranges
                          ;; When there's no range for the embedded
                          ;; language, set it's range to a dummy (1
                          ;; . 1), otherwise it would be set to the
                          ;; whole buffer, which is not what we want.
                          `((,(point-min) . ,(point-min)))))))))))

    (treesit--cleanup-local-range-overlays modified-tick beg end)))

(defun treesit-parser-range-on (parser beg &optional end)
  "Check if PARSER's range covers the portion between BEG and END.

If it does, return the range covering that portion in the form
of (RANGE-BEG . RANGE-END), if not, return nil.  If nil or
omitted, default END to BEG."
  (let ((ranges (treesit-parser-included-ranges parser))
        (end (or end beg)))
    (if (null ranges)
        (cons (point-min) (point-max))
      (cl-loop for rng in ranges
               if (<= (car rng) beg end (cdr rng))
               return rng
               finally return nil))))

;;; Fontification

(define-error 'treesit-font-lock-error
              "Generic tree-sitter font-lock error"
              'treesit-error)

;; The primary parser will be access frequently (after each re-parse,
;; before redisplay, etc, see
;; `treesit--font-lock-mark-ranges-to-fontify'), so we don't want to
;; allow it to be a callback function which returns the primary parser
;; (it might be slow).  It's not something that needs to be dynamic
;; anyway.
(defvar-local treesit-primary-parser nil
  "The primary parser for this buffer.

The primary parser should be a parser that parses the entire buffer, as
opposed to embedded parsers which parses only part of the buffer.")

(defvar-local treesit-font-lock-settings nil
  "A list of SETTINGs for treesit-based fontification.

The exact format of each SETTING is considered internal.  Use
`treesit-font-lock-rules' to set this variable.

Each SETTING has the form:

    (QUERY ENABLE FEATURE OVERRIDE)

QUERY must be a compiled query.  See Info node `(elisp)Pattern
Matching' for how to write a query and compile it.

For SETTING to be activated for font-lock, ENABLE must be t.  To
disable this SETTING, set ENABLE to nil.

FEATURE is the \"feature name\" of the query.  Users can control
which features are enabled with `treesit-font-lock-level' and
`treesit-font-lock-feature-list'.

OVERRIDE is the override flag for this query.  Its value can be
t, nil, append, prepend, keep.  See more in
`treesit-font-lock-rules'.")

(defsubst treesit--font-lock-setting-feature (setting)
  "Return the feature of SETTING.
SETTING should be a setting in `treesit-font-lock-settings'."
  (nth 2 setting))

(defsubst treesit--font-lock-setting-enable (setting)
  "Return enabled SETTING."
  (let ((new-setting (copy-tree setting)))
    (setf (nth 1 new-setting) t)
    new-setting))

(defun treesit--font-lock-level-setter (sym val)
  "Custom setter for `treesit-font-lock-level'.
Set the default value of SYM to VAL, recompute fontification
features and refontify for every buffer where tree-sitter-based
fontification is enabled."
  (set-default sym val)
  (and (treesit-available-p)
       (named-let loop ((res nil)
                        (buffers (buffer-list)))
         (if (null buffers)
             (mapc (lambda (b)
                     (with-current-buffer b
                       (setq-local treesit-font-lock-level val)
                       (treesit-font-lock-recompute-features)
                       (treesit-font-lock-fontify-region (point-min)
                                                         (point-max))))
                   res)
           (let ((buffer (car buffers)))
             (with-current-buffer buffer
               (if treesit-font-lock-settings
                   (loop (append res (list buffer)) (cdr buffers))
                 (loop res (cdr buffers)))))))))

(defcustom treesit-font-lock-level 3
  "Decoration level to be used by tree-sitter fontifications.

Major modes categorize their fontification features into levels,
from 1 which is the absolute minimum, to 4 that yields the maximum
fontifications.

Level 1 usually contains only comments and definitions.
Level 2 usually adds keywords, strings, data types, etc.
Level 3 usually represents full-blown fontifications, including
assignments, constants, numbers and literals, etc.
Level 4 adds everything else that can be fontified: delimiters,
operators, brackets, punctuation, all functions, properties,
variables, etc.

In addition to the decoration level, individual features can be
turned on/off by calling `treesit-font-lock-recompute-features'.
Changing the decoration level requires calling
`treesit-font-lock-recompute-features' to have an effect, unless
done via `customize-variable'.

To see which syntactical categories are fontified by each level
in a particular major mode, examine the buffer-local value of the
variable `treesit-font-lock-feature-list'."
  :type 'integer
  :set #'treesit--font-lock-level-setter
  :version "29.1")

(defvar-local treesit--font-lock-query-expand-range (cons 0 0)
  "The amount to expand the start and end of the region when fontifying.
This should be a cons cell (START . END).  When fontifying a
buffer, Emacs will move the start of the query range backward by
START amount, and the end of the query range by END amount.  Both
START and END should be positive integers or 0.  This doesn't
affect the fontified range.")

(defvar-local treesit-font-lock-feature-list nil
  "A list of lists of feature symbols.

Use `treesit-font-lock-recompute-features' and
`treesit-font-lock-level' to configure enabled features.

Each sublist represents a decoration level.
`treesit-font-lock-level' controls which levels are activated.

Inside each sublist are feature symbols, which correspond to the
:feature value of a query defined in `treesit-font-lock-rules'.
Removing a feature symbol from this list disables the
corresponding query during font-lock.

Common feature names (for general programming languages) include
definition, type, assignment, builtin, constant, keyword,
string-interpolation, comment, doc, string, operator, property,
preprocessor, escape-sequence, key (in key-value pairs).  Major
modes are free to subdivide or extend on these common features.
See the manual for more explanations on some of the features.

For changes to this variable to take effect, run
`treesit-font-lock-recompute-features'.")

(defun treesit-font-lock-rules (&rest query-specs)
  "Return a value suitable for `treesit-font-lock-settings'.

QUERY-SPECS is a series of QUERY-SPECs.  Each QUERY-SPEC is a
QUERY preceded by multiple pairs of :KEYWORD and VALUE:

   :KEYWORD VALUE... QUERY

QUERY is a tree-sitter query in either the string, s-expression
or compiled form.  For each query, captured nodes are highlighted
with the capture name as its face.

:KEYWORD and VALUE pairs preceding a QUERY add meta information
to QUERY.  For example,

    (treesit-font-lock-rules
     :language \\='javascript
     :override t
     :feature\\='constant
     \\='((true) @font-lock-constant-face
       (false) @font-lock-constant-face)
     :language \\='html
     :feature \\='script
     \"(script_element) @font-lock-builtin-face\")

For each QUERY, a :language keyword and a :feature keyword are
required.  Each query's :feature is a symbol summarizing what the
query fontifies.  It is used to allow users to enable/disable
certain features.  See `treesit-font-lock-feature-list' for more.
Other keywords include:

  KEYWORD    VALUE      DESCRIPTION
  :override  nil        If the region already has a face,
                        discard the new face.
             t          Always apply the new face.
             `append'   Append the new face to existing ones.
             `prepend'  Prepend the new face to existing ones.
             `keep'     Fill-in regions without an existing face.
  :default-language  LANGUAGE  Every QUERY after this keyword
                               will use LANGUAGE by default.

Capture names in QUERY should be face names like
`font-lock-keyword-face'.  The captured node will be fontified
with that face.

Capture names can also be function names, in which case the
function will be called with the following argument list:

    (NODE OVERRIDE START END &rest _)

where NODE is the tree-sitter node object, OVERRIDE is the
override option of that rule, and START and END specify the region
to be fontified.  This function should accept more arguments as
optional arguments for future extensibility, and it shouldn't
fontify text outside the region given by START and END.

If a capture name is both a face and a function, the face takes
priority.  If a capture name is not a face name nor a function
name, it is ignored."
  ;; Other tree-sitter function don't tend to be called unless
  ;; tree-sitter is enabled, which means tree-sitter must be compiled.
  ;; But this function is usually call in `defvar' which runs
  ;; regardless whether tree-sitter is enabled.  So we need this
  ;; guard.
  (when (treesit-available-p)
    (let (;; Tracks the current :language/:override/:toggle/:level value
          ;; that following queries will apply to.
          current-language current-override
          current-feature
          ;; DEFAULT-LANGUAGE will be chosen when current-language is
          ;; not set.
          default-language
          ;; The list this function returns.
          (result nil))
      (while query-specs
        (let ((token (pop query-specs)))
          (pcase token
            ;; (1) Process keywords.
            (:default-language
             (let ((lang (pop query-specs)))
               (when (or (not (symbolp lang)) (null lang))
                 (signal 'treesit-font-lock-error
                         `("Value of :default-language should be a symbol"
                           ,lang)))
               (setq default-language lang)))
            (:language
             (let ((lang (pop query-specs)))
               (when (or (not (symbolp lang)) (null lang))
                 (signal 'treesit-font-lock-error
                         `("Value of :language should be a symbol"
                           ,lang)))
               (setq current-language lang)))
            (:override
             (let ((flag (pop query-specs)))
               (when (not (memq flag '(t nil append prepend keep)))
                 (signal 'treesit-font-lock-error
                         `("Value of :override should be one of t, nil, append, prepend, keep"
                           ,flag))
                 (signal 'wrong-type-argument
                         `((or t nil append prepend keep)
                           ,flag)))
               (setq current-override flag)))
            (:feature
             (let ((var (pop query-specs)))
               (when (or (not (symbolp var))
                         (memq var '(t nil)))
                 (signal 'treesit-font-lock-error
                         `("Value of :feature should be a symbol"
                           ,var)))
               (setq current-feature var)))
            ;; (2) Process query.
            ((pred treesit-query-p)
             (let ((lang (or default-language current-language)))
               (when (null lang)
                 (signal 'treesit-font-lock-error
                         `("Language unspecified, use :language keyword or :default-language to specify a language for this query" ,token)))
               (when (null current-feature)
                 (signal 'treesit-font-lock-error
                         `("Feature unspecified, use :feature keyword to specify the feature name for this query" ,token)))
               (if (treesit-compiled-query-p token)
                   (push `(,lang token) result)
                 (push `(,(treesit-query-compile lang token)
                         t
                         ,current-feature
                         ,current-override)
                       result))
               ;; Clears any configurations set for this query.
               (setq current-language nil
                     current-override nil
                     current-feature nil)))
            (_ (signal 'treesit-font-lock-error
                       `("Unexpected value" ,token))))))
      (nreverse result))))

;; `font-lock-fontify-region-function' has the LOUDLY argument, but
;; `jit-lock-functions' doesn't pass that argument.  So even if we set
;; `font-lock-verbose' to t, if jit-lock is enabled (and it's almost
;; always is), we don't get debug messages.  So we add our own.
(defvar treesit--font-lock-verbose nil
  "If non-nil, print debug messages when fontifying.")

(defun treesit-font-lock-recompute-features
    (&optional add-list remove-list language)
  "Enable/disable font-lock features.

Enable each feature in ADD-LIST, disable each feature in
REMOVE-LIST.

If both ADD-LIST and REMOVE-LIST are omitted, recompute each
feature according to `treesit-font-lock-feature-list' and
`treesit-font-lock-level'.  If the value of `treesit-font-lock-level',
is N, then the features in the first N sublists of
`treesit-font-lock-feature-list' are enabled, and the rest of
the features are disabled.

ADD-LIST and REMOVE-LIST are lists of feature symbols.  The
same feature symbol cannot appear in both lists; the function
signals the `treesit-font-lock-error' error if that happens.

If LANGUAGE is non-nil, only compute features for that language,
and leave settings for other languages unchanged."
  (when-let ((intersection (cl-intersection add-list remove-list)))
    (signal 'treesit-font-lock-error
            (list "ADD-LIST and REMOVE-LIST contain the same feature"
                  intersection)))
  (let* ((level treesit-font-lock-level)
         (base-features (cl-loop
                         for idx = 0 then (1+ idx)
                         for features in treesit-font-lock-feature-list
                         if (or (eq level t)
                                (>= level (1+ idx)))
                         append features))
         (features (cl-set-difference (cl-union base-features add-list)
                                      remove-list))
         ;; If additive non-nil, we are configuring on top of the
         ;; existing configuration, if nil, we are resetting
         ;; everything according to `treesit-font-lock-feature-list'.
         (additive (or add-list remove-list)))
    (cl-loop for idx = 0 then (1+ idx)
             for setting in treesit-font-lock-settings
             for lang = (treesit-query-language (nth 0 setting))
             for feature = (nth 2 setting)
             for current-value = (nth 1 setting)
             ;; Set the ENABLE flag for the setting if its language is
             ;; relevant.
             if (or (null language)
                    (eq language lang))
             do (setf (nth 1 (nth idx treesit-font-lock-settings))
                      (cond
                       ((not additive)
                        (if (memq feature features) t nil))
                       ((memq feature add-list) t)
                       ((memq feature remove-list) nil)
                       (t current-value))))))

(defun treesit-add-font-lock-rules (rules &optional how feature)
  "Add font-lock RULES to the current buffer.

RULES should be the return value of `treesit-font-lock-rules'.  RULES
will be enabled and added to `treesit-font-lock-settings'.

HOW can be either :before or :after.  If HOW is :before, prepend RULES
before all other existing font-lock rules in
`treesit-font-lock-settings'; if :after or omitted, append RULES after
all existing rules.

If FEATURE is non-nil, add RULES before/after rules for FEATURE.  See
docstring of `treesit-font-lock-rules' for what is a feature."
  (let ((rules (seq-map #'treesit--font-lock-setting-enable rules))
        (feature-idx
         (when feature
           (cl-position-if
            (lambda (setting)
              (eq (treesit--font-lock-setting-feature setting) feature))
            treesit-font-lock-settings))))
    (pcase (cons how feature)
      ((or '(:after . nil) '(nil . nil))
       (setq treesit-font-lock-settings
             (append treesit-font-lock-settings rules)))
      ('(:before . nil)
       (setq treesit-font-lock-settings
             (append rules treesit-font-lock-settings)))
      (`(:after . ,_feature)
       (setf (nthcdr (1+ feature-idx) treesit-font-lock-settings)
             (append rules
                     (nthcdr (1+ feature-idx)
                             treesit-font-lock-settings))))
      (`(:before . ,_feature)
       (setf (nthcdr feature-idx treesit-font-lock-settings)
             (append rules
                     (nthcdr feature-idx treesit-font-lock-settings)))))))

(defun treesit-fontify-with-override
    (start end face override &optional bound-start bound-end)
  "Apply FACE to the region between START and END.
OVERRIDE can be nil, t, `append', `prepend', or `keep'.
See `treesit-font-lock-rules' for their semantics.

If BOUND-START and BOUND-END are non-nil, only fontify the region
in between them."
  (when (or (null bound-start) (null bound-end)
            (and (<= bound-start end)
                 (>= bound-end start)))
    (when (and bound-start bound-end)
      (setq start (max bound-start start)
            end (min bound-end end)))
    (pcase override
      ('nil (unless (text-property-not-all start end 'face nil)
              (put-text-property start end 'face face)))
      ('t (put-text-property start end 'face face))
      ('append (font-lock-append-text-property
                start end 'face face))
      ('prepend (font-lock-prepend-text-property
                 start end 'face face))
      ('keep (font-lock-fillin-text-property
              start end 'face face))
      (_ (signal 'treesit-font-lock-error
                 (list
                  "Unrecognized value of :override option"
                  override))))))

(defun treesit--set-nonsticky (start end sym &optional remove)
  "Set `rear-nonsticky' property between START and END.
Set the property to a list containing SYM.  If there is already a
list, add SYM to that list.  If REMOVE is non-nil, remove SYM
instead."
  (let* ((prop (get-text-property start 'rear-nonsticky))
         (new-prop
          (pcase prop
            ((pred listp) ; PROP is a list or nil.
             (if remove
                 (remove sym prop)
               ;; We should make sure PORP doesn't contain SYM, but
               ;; whatever.
               (cons sym prop)))
            ;; PROP is t.
            (_ (if remove
                   nil
                 (list sym))))))
    (if (null new-prop)
        (remove-text-properties start end '(rear-nonsticky nil))
      (put-text-property start end 'rear-nonsticky new-prop))))

(defun treesit--children-covering-range (node start end)
  "Return a list of children of NODE covering a range.
The range is between START and END."
  (if-let* ((child (treesit-node-first-child-for-pos node start))
            (result (list child)))
      (progn
        (while (and child (< (treesit-node-end child) end)
                    (setq child (treesit-node-next-sibling child)))
          (push child result))
        (nreverse result))
    (list node)))

(defun treesit--children-covering-range-recurse
    (node start end threshold &optional limit)
  "Return a list of children of NODE covering a range.

Recursively go down the parse tree and collect children, until
all nodes in the returned list are smaller than THRESHOLD.  The
range is between START and END.

LIMIT is the recursion limit, which defaults to 100."
  (let* ((child (treesit-node-first-child-for-pos node start))
         (limit (or limit 100))
         result)
    ;; If LIMIT is exceeded, we are probably seeing the erroneously
    ;; tall tree, in that case, just give up.
    (while (and (> limit 0) child (<= (treesit-node-start child) end))
      ;; If child still too large, recurse down.  Otherwise collect
      ;; child.
      (if (> (- (treesit-node-end child)
                (treesit-node-start child))
             threshold)
          (dolist (r (treesit--children-covering-range-recurse
                      child start end threshold (1- limit)))
            (push r result))
        (push child result))
      (setq child (treesit-node-next-sibling child)))
    ;; If NODE has no child, keep NODE.  If LIMIT is exceeded, return
    ;; nil.
    (or result (and (> limit 0) (list node)))))

(defsubst treesit--node-length (node)
  "Return the length of the text of NODE."
  (- (treesit-node-end node) (treesit-node-start node)))

(defvar-local treesit--font-lock-fast-mode 'unspecified
  "If this variable is t, change the way we query so it's faster.
This is not a general optimization and should be RARELY needed!
See comments in `treesit-font-lock-fontify-region' for more
detail.")

;; Some details worth explaining:
;;
;; 1. When we apply face to a node, we clip the face into the
;; currently fontifying region, this way we don't overwrite faces
;; applied by regexp-based font-lock.  The clipped part will be
;; fontified fine when Emacs fontifies the region containing it.
;;
;; 2. If you insert an ending quote into a buffer, jit-lock only wants
;; to fontify that single quote, and (treesit-node-on start end) will
;; give you that quote node.  We want to capture the string and apply
;; string face to it, but querying on the quote node will not give us
;; the string node.  So we don't use treesit-node-on: using the root
;; node with a restricted range is very fast anyway (even in large
;; files of size ~10MB).  Plus, querying the result of
;; `treesit-node-on' could still miss patterns even if we use some
;; heuristic to enlarge the node (how much to enlarge? to which
;; extent?), it's much safer to just use the root node.
;;
;; Sometimes the source file has some errors that cause tree-sitter to
;; parse it into a enormously tall tree (10k levels tall).  In that
;; case querying the root node is very slow.  So we try to get
;; top-level nodes and query them.  This ensures that querying is fast
;; everywhere else, except for the problematic region.  (Bug#59415).
;;
;; Some other time the source file has a top-level node that contains
;; a huge number of immediate children (say, 10k children), querying
;; that node is also very slow, so instead of getting the top-level
;; node, we recursively go down the tree to find nodes that cover the
;; region but are reasonably small.  (Bug#59738).
;;
;; 3. It is possible to capture a node that's completely outside the
;; region between START and END: as long as the whole pattern
;; intersects the region, all the captured nodes in that pattern are
;; returned.  If the node is outside of that region, (max node-start
;; start) and friends return bad values, so we filter them out.
;; However, we don't filter these nodes out if a function will process
;; the node, because it could (and often do) fontify the relatives of
;; the captured node, not just the node itself.  If we took out those
;; nodes author of those functions would be very confused.
(defun treesit-font-lock-fontify-region (start end &optional loudly)
  "Fontify the region between START and END.
If LOUDLY is non-nil, display some debugging information."
  (when (or loudly treesit--font-lock-verbose)
    (message "Fontifying region: %s-%s" start end))
  (treesit-update-ranges start end)
  (font-lock-unfontify-region start end)
  (let* ((local-parsers (treesit-local-parsers-on start end))
         (global-parsers (treesit-parser-list))
         (root-nodes
          (mapcar #'treesit-parser-root-node
                  (append local-parsers global-parsers))))
    (dolist (setting treesit-font-lock-settings)
      (let* ((query (nth 0 setting))
             (enable (nth 1 setting))
             (override (nth 3 setting))
             (language (treesit-query-language query))
             (root-nodes (cl-remove-if-not
                          (lambda (node)
                            (eq (treesit-node-language node) language))
                          root-nodes)))

        ;; Use deterministic way to decide whether to turn on "fast
        ;; mode". (See bug#60691, bug#60223.)
        (when (eq treesit--font-lock-fast-mode 'unspecified)
          (pcase-let ((`(,max-depth ,max-width)
                       (treesit-subtree-stat
                        (treesit-buffer-root-node language))))
            (if (or (> max-depth 100) (> max-width 4000))
                (setq treesit--font-lock-fast-mode t)
              (setq treesit--font-lock-fast-mode nil))))

        ;; Only activate if ENABLE flag is t.
        (when-let
            ((activate (eq t enable))
             (nodes (if (eq t treesit--font-lock-fast-mode)
                        (mapcan
                         (lambda (node)
                           (treesit--children-covering-range-recurse
                            node start end (* 4 jit-lock-chunk-size)))
                         root-nodes)
                      root-nodes)))
          (ignore activate)

          ;; Query each node.
          (dolist (sub-node nodes)
            (treesit--font-lock-fontify-region-1
             sub-node query start end override loudly))))))
  `(jit-lock-bounds ,start . ,end))

(defun treesit--font-lock-fontify-region-1 (node query start end override loudly)
  "Fontify the region between START and END by querying NODE with QUERY.

If OVERRIDE is non-nil, override existing faces, if LOUDLY is
non-nil, print debugging information."
  (let* ((delta-start (car treesit--font-lock-query-expand-range))
         (delta-end (cdr treesit--font-lock-query-expand-range))
         (captures (treesit-query-capture
                    node query
                    (max (- start delta-start) (point-min))
                    (min (+ end delta-end) (point-max)))))

    ;; For each captured node, fontify that node.
    (with-silent-modifications
      (dolist (capture captures)
        (let* ((face (car capture))
               (node (cdr capture))
               (node-start (treesit-node-start node))
               (node-end (treesit-node-end node)))

          ;; If node is not in the region, take them out.  See
          ;; comment #3 above for more detail.
          (if (and (facep face)
                   (or (>= start node-end) (>= node-start end)))
              (when (or loudly treesit--font-lock-verbose)
                (message "Captured node %s(%s-%s) but it is outside of fontifing region" node node-start node-end))

            (cond
             ((facep face)
              (treesit-fontify-with-override
               (max node-start start) (min node-end end)
               face override))
             ((functionp face)
              (funcall face node override start end)))

            ;; Don't raise an error if FACE is neither a face nor
            ;; a function.  This is to allow intermediate capture
            ;; names used for #match and #eq.
            (when (or loudly treesit--font-lock-verbose)
              (message "Fontifying text from %d to %d, Face: %s, Node: %s"
                       (max node-start start) (min node-end end)
                       face (treesit-node-type node)))))))))

(defvar-local treesit--syntax-propertize-start nil
  "If non-nil, next `syntax-propertize' should start at this position.

When tree-sitter parser reparses, it calls
`treesit--font-lock-mark-ranges-to-fontify' with the changed ranges, and
that function sets this variable to the start of the changed ranges.")

(defvar-local treesit--pre-redisplay-tick nil
  "The last `buffer-chars-modified-tick' that we've processed.
Because `pre-redisplay-functions' could be called multiple times
during a single command loop, we use this variable to debounce
calls to `treesit--pre-redisplay'.")

(defun treesit--font-lock-mark-ranges-to-fontify (ranges _parser)
  "A notifier that marks ranges that needs refontification.

For RANGES and PARSER see `treesit-parser-add-notifier'.

After the parser reparses, we get the changed ranges, and
1) update non-primary parsers' ranges in the changed ranges
2) mark these ranges as to-be-fontified,
3) tell `syntax-ppss' to start reparsing from the min point of the
   ranges.

We need to mark to-be-fontified ranges before redisplay starts working,
because sometimes the range edited by the user is not the only range
that needs to be refontified.  For example, when the user types the
final slash of a C block comment /* xxx */, not only do we need to
fontify the slash, but also the whole block comment, which previously
wasn't fontified as comment due to incomplete parse tree."
  (dolist (range ranges)
    ;; 1. Update ranges.
    (treesit-update-ranges (car range) (cdr range))
    ;; 2. Mark the changed ranges to be fontified.
    (when treesit--font-lock-verbose
      (message "Notifier received range: %s-%s"
               (car range) (cdr range)))
    (with-silent-modifications
      (put-text-property (car range) (cdr range) 'fontified nil))
    ;; 3. Set `treesit--syntax-propertize-start'.
    (if (null treesit--syntax-propertize-start)
        (setq treesit--syntax-propertize-start (car range))
      (setq treesit--syntax-propertize-start
            (min treesit--syntax-propertize-start (car range))))))

(defun treesit--guess-primary-parser ()
  "Guess the primary parser of the current buffer and return it.

Normally in a tree-sitter major mode, there is a primary parser that
parses the entire buffer (as opposed to embedded parsers which only
parses part of the buffer).  This function tries to find and return that
parser."
  (if treesit-range-settings
      (let ((query (car (car treesit-range-settings))))
        (if (treesit-query-p query)
            (treesit-parser-create
             (treesit-query-language query))
          (car (treesit-parser-list))))
    (car (treesit-parser-list))))

(defun treesit--pre-redisplay (&rest _)
  "Force a reparse on the primary parser and mark regions to be fontified.

The actual work is carried out by
`treesit--font-lock-mark-ranges-to-fontify', which see."
  (unless (eq treesit--pre-redisplay-tick (buffer-chars-modified-tick))
    (when treesit-primary-parser
      ;; Force a reparse on the primary parser, if everything is setup
      ;; correctly, the parser should call
      ;; `treesit--font-lock-mark-ranges-to-fontify' (which should be a
      ;; notifier function of the primary parser).
      (treesit-parser-root-node treesit-primary-parser))

    (setq treesit--pre-redisplay-tick (buffer-chars-modified-tick))))

(defun treesit--pre-syntax-ppss (start end)
  "Force reparse and consequently run all notifiers.

Similar to font-lock, we want to update the `syntax' text
property before `syntax-ppss' starts working on the text.  We
also want to extend the to-be-propertized region to include the
whole region affected by the last reparse.

START and END mark the current to-be-propertized region."
  (treesit--pre-redisplay)
  ;; `treesit--syntax-propertize-start' is set by
  ;; `treesit--font-lock-mark-ranges-to-fontify', which is called after
  ;; each re-parser on the primary parser and in
  ;; `treesit--pre-redisplay'.
  (let ((new-start treesit--syntax-propertize-start))
    (if (and new-start (< new-start start))
        (progn
          (setq treesit--syntax-propertize-start nil)
          (cons (max new-start (point-min)) end))
      nil)))

;;; Indent

(define-error 'treesit-indent-error
              "Generic tree-sitter indentation error"
              'treesit-error)

(defvar treesit--indent-verbose nil
  "If non-nil, log progress when indenting.")

(defvar-local treesit-simple-indent-rules nil
  "A list of indent rule settings.
Each indent rule setting should be (LANGUAGE . RULES),
where LANGUAGE is a language symbol, and RULES is a list of

    (MATCHER ANCHOR OFFSET).

MATCHER determines whether this rule applies, ANCHOR and OFFSET
together determines which column to indent to.

A MATCHER is a function that takes three arguments (NODE PARENT
BOL).  BOL is the point where we are indenting: the beginning of
line content, the position of the first non-whitespace character.
NODE is the largest (highest-in-tree) node starting at that
point.  PARENT is the parent of NODE.

If MATCHER returns non-nil, meaning the rule matches, Emacs then
uses ANCHOR to find an anchor, it should be a function that takes
the same argument (NODE PARENT BOL) and returns a point.

Finally Emacs computes the column of that point returned by
ANCHOR and adds OFFSET to it, and indents to that column.  OFFSET
can be an integer or a variable whose value is an integer.

For MATCHER and ANCHOR, Emacs provides some convenient presets.
See `treesit-simple-indent-presets'.")

(defvar treesit-simple-indent-presets
  (list (cons 'match
              (lambda
                (&optional node-type parent-type node-field
                           node-index-min node-index-max)
                (lambda (node parent &rest _)
                  (and (pcase node-type
                         ('nil t)
                         ('null (null node))
                         (_ (string-match-p
                             node-type (or (treesit-node-type node) ""))))
                       (or (null parent-type)
                           (string-match-p
                            parent-type (treesit-node-type parent)))
                       (or (null node-field)
                           (string-match-p
                            node-field
                            (or (treesit-node-field-name node) "")))
                       (or (null node-index-min)
                           (>= (treesit-node-index node)
                               node-index-min))
                       (or (null node-index-max)
                           (<= (treesit-node-index node)
                               node-index-max))))))
        (cons 'n-p-gp
              (lambda (node-t parent-t grand-parent-t)
                (lambda (node parent &rest _)
                  (and (or (null node-t)
                           (string-match-p
                            node-t (or (treesit-node-type node) "")))
                       (or (null parent-t)
                           (string-match-p
                            parent-t (treesit-node-type parent)))
                       (or (null grand-parent-t)
                           (and
                            (treesit-node-parent parent)
                            (string-match-p
                             grand-parent-t
                             (treesit-node-type
                              (treesit-node-parent parent)))))))))
        (cons 'no-node (lambda (node &rest _) (null node)))
        (cons 'parent-is (lambda (type)
                           (lambda (_n parent &rest _)
                             (string-match-p
                              type (treesit-node-type parent)))))

        (cons 'node-is (lambda (type)
                         (lambda (node &rest _)
                           (string-match-p
                            type (or (treesit-node-type node) "")))))
        (cons 'field-is (lambda (name)
                          (lambda (node &rest _)
                            (string-match-p
                             name (or (treesit-node-field-name node) "")))))
        (cons 'comment-end (lambda (_node _parent bol &rest _)
                             (save-excursion
                               (goto-char bol)
                               (looking-at-p comment-end-skip))))
        (cons 'catch-all (lambda (&rest _) t))

        (cons 'query (lambda (pattern)
                       (lambda (node parent &rest _)
                         (cl-loop for capture
                                  in (treesit-query-capture
                                      parent pattern)
                                  if (treesit-node-eq node (cdr capture))
                                  return t
                                  finally return nil))))
        (cons 'first-sibling (lambda (_n parent &rest _)
                               (treesit-node-start
                                (treesit-node-child parent 0))))
        (cons 'nth-sibling (lambda (n &optional named)
                             (lambda (_n parent &rest _)
                               (treesit-node-start
                                (treesit-node-child parent n named)))))
        (cons 'parent (lambda (_n parent &rest _)
                        (treesit-node-start parent)))
        (cons 'comment-start
              (lambda (_n parent &rest _)
                (save-excursion
                  (goto-char (treesit-node-start parent))
                  (re-search-forward comment-start-skip)
                  (skip-syntax-backward "-")
                  (point))))
        (cons 'prev-adaptive-prefix
              (lambda (_n parent bol &rest _)
                (let (comment-start-bol
                      this-line-has-prefix)
                  (save-excursion
                    (goto-char (treesit-node-start parent))
                    (setq comment-start-bol (line-beginning-position))

                    (goto-char bol)
                    (setq this-line-has-prefix
                          (and (looking-at adaptive-fill-regexp)
                               (not (string-match-p
                                     (rx bos (* whitespace) eos)
                                     (match-string 0)))))

                    (forward-line -1)
                    (and (>= (point) comment-start-bol)
                         adaptive-fill-regexp
                         (looking-at adaptive-fill-regexp)
                         ;; If previous line is an empty line, don't
                         ;; indent.
                         (not (looking-at-p (rx (* whitespace) eol)))
                         ;; Return the anchor.  If the indenting line
                         ;; has a prefix and the previous line also
                         ;; has a prefix, indent to the beginning of
                         ;; prev line's prefix rather than the end of
                         ;; prev line's prefix. (Bug#61314).
                         (or (and this-line-has-prefix
                                  (match-beginning 1))
                             (match-end 0)))))))
        (cons 'grand-parent
              (lambda (_n parent &rest _)
                (treesit-node-start (treesit-node-parent parent))))
        (cons 'great-grand-parent
              (lambda (_n parent &rest _)
                (treesit-node-start
                 (treesit-node-parent
                  (treesit-node-parent parent)))))
        (cons 'parent-bol (lambda (_n parent &rest _)
                            (save-excursion
                              (goto-char (treesit-node-start parent))
                              (back-to-indentation)
                              (point))))
        (cons 'standalone-parent
              (lambda (_n parent &rest _)
                (save-excursion
                  (catch 'term
                    (while parent
                      (goto-char (treesit-node-start parent))
                      (when (looking-back (rx bol (* whitespace))
                                          (line-beginning-position))
                        (throw 'term (point)))
                      (setq parent (treesit-node-parent parent)))))))
        (cons 'prev-sibling (lambda (node parent bol &rest _)
                              (treesit-node-start
                               (or (treesit-node-prev-sibling node t)
                                   ;; If node is nil (indenting empty
                                   ;; line), we still try to guess the
                                   ;; previous sibling.
                                   (treesit-node-prev-sibling
                                    (treesit-node-first-child-for-pos
                                     parent bol)
                                    t)
                                   (treesit-node-child parent -1 t)))))
        (cons 'no-indent (lambda (_n _p bol &rest _) bol))
        (cons 'prev-line (lambda (_n _p bol &rest _)
                           (save-excursion
                             (goto-char bol)
                             (forward-line -1)
                             (skip-chars-forward " \t")
                             (point))))
        (cons 'column-0 (lambda (_n _p bol &rest _)
                          (save-excursion
                            (goto-char bol)
                            (line-beginning-position))))
        ;; TODO: Document.
        (cons 'and (lambda (&rest fns)
                     (lambda (node parent bol &rest _)
                       (let (res)
                         (catch 'break
                           (dolist (fn fns)
                             (setq res (funcall fn node parent bol))
                             (unless res (throw 'break t))))
                         res))))
        (cons 'or (lambda (&rest fns)
                    (lambda (node parent bol &rest _)
                      (let (res)
                        (catch 'break
                          (dolist (fn fns)
                            (setq res (funcall fn node parent bol))
                            (and res (throw 'break t))))
                        res))))
        (cons 'not (lambda (fn)
                     (lambda (node parent bol &rest _)
                       (not (funcall fn node parent bol)))))
        (cons 'list (lambda (&rest fns)
                      (lambda (node parent bol &rest _)
                        (mapcar (lambda (fn)
                                  (funcall fn node parent bol))
                                fns)))))
  "A list of indent rule presets.
These presets can be used as MATCHER and ANCHOR values in
`treesit-simple-indent-rules'.  MATCHERs and ANCHORs are
functions that take 3 arguments: NODE, PARENT, and BOL.

MATCHER:

\(match NODE-TYPE PARENT-TYPE NODE-FIELD NODE-INDEX-MIN NODE-INDEX-MAX)

    NODE-TYPE checks for NODE's type, PARENT-TYPE checks for
    PARENT's type, NODE-FIELD checks for the field name of NODE
    in PARENT, NODE-INDEX-MIN and NODE-INDEX-MAX check for
    NODE's index in PARENT.  Therefore, to match the first child
    where PARENT is \"argument_list\", use

        (match nil \"argument_list\" nil 0 0).

    NODE-TYPE, PARENT-TYPE, and NODE-FIELD are regexps.
    NODE-TYPE can also be `null', which matches when NODE is nil.

no-node

    Matches the case where NODE is nil, i.e., there is no node
    that starts at point.  This is the case when indenting an
    empty line.

\(parent-is TYPE)

    Check that PARENT's type matches regexp TYPE.

\(node-is TYPE)

    Checks that NODE's type matches regexp TYPE.

\(field-is NAME)

    Checks that NODE's field name in PARENT matches regexp NAME.

\(n-p-gp NODE-TYPE PARENT-TYPE GRANDPARENT-TYPE)

    Checks for NODE's, its parent's, and its grandparent's type.

\(query QUERY)

    Queries PARENT with QUERY, and checks if NODE is
    captured (by any capture name).

comment-end

    Matches if text after point matches `comment-end-skip'.

catch-all

    Always matches.

ANCHOR:

first-sibling

    Returns the start of the first child of PARENT.

\(nth-sibling N &optional NAMED)

    Returns the start of the Nth child of PARENT.
    NAMED non-nil means count only named nodes.

parent

    Returns the start of PARENT.

grand-parent

    Returns the start of PARENT's parent.

great-grand-parent

    Returns the start of PARENT's parent's parent.

parent-bol

    Returns the beginning of non-space characters on the line where
    PARENT is on.

standalone-parent

    Finds the first ancestor node (parent, grandparent, etc.) that
    starts on its own line, and returns the start of that node.

prev-sibling

    Returns the start of NODE's previous sibling.

no-indent

    Returns the start of NODE.

prev-line

    Returns the first non-whitespace character on the previous line.

column-0

    Returns the beginning of the current line, which is at column 0.

comment-start

    Goes to the position that `comment-start-skip' would return,
    skips whitespace backwards, and returns the resulting
    position.  Assumes PARENT is a comment node.

prev-adaptive-prefix

    Goes to the beginning of previous non-empty line, and tries
    to match `adaptive-fill-regexp'.  If it matches, return the
    end of the match, otherwise return nil.  However, if the
    current line begins with a prefix, return the beginning of
    the prefix of the previous line instead, so that the two
    prefixes aligns.  This is useful for an `indent-relative'-like
    indent behavior for block comments.")

(defun treesit--simple-indent-eval (exp)
  "Evaluate EXP.

If EXP is an application and the function is a key in
`treesit-simple-indent-presets', use the corresponding value as
the function."
  ;; We don't want to match uncompiled lambdas, so make sure this cons
  ;; is not a function.  We could move the condition functionp
  ;; forward, but better be explicit.
  (cond ((and (consp exp) (not (functionp exp)))
         (apply (treesit--simple-indent-eval (car exp))
                (mapcar #'treesit--simple-indent-eval
                        (cdr exp))))
        ;; Presets override functions, so this condition comes before
        ;; `functionp'.
        ((alist-get exp treesit-simple-indent-presets))
        ((functionp exp) exp)
        ((symbolp exp)
         (if (null exp)
             exp
           ;; Matchers only return lambdas, anchors only return
           ;; integer, so we should never see a variable.
           (signal 'treesit-indent-error
                   (list "Couldn't find the preset corresponding to expression"
                         exp))))
        (t exp)))

;; This variable might seem unnecessary: why split
;; `treesit-indent' and `treesit-simple-indent' into two
;; functions?  We add this variable in between because later we might
;; add more powerful indentation engines, and that new engine can
;; probably share `treesit-indent'.  It is also useful, suggested
;; by Stefan M, to have a function that figures out how much to indent
;; but doesn't actually performs the indentation, because we might
;; want to know where will a node indent to if we put it at some other
;; location, and use that information to calculate the actual
;; indentation.  And `treesit-simple-indent' is that function.  I
;; forgot the example Stefan gave, but it makes a lot of sense.
(defvar treesit-indent-function #'treesit-simple-indent
  "Function used by `treesit-indent' to do some of the work.

This function is called with

    (NODE PARENT BOL &rest _)

and returns

    (ANCHOR . OFFSET).

BOL is the position of the beginning of the line; NODE is the
\"largest\" node that starts at BOL (and isn't a root node);
PARENT is its parent; ANCHOR is a point (not a node), and OFFSET
is a number.  Emacs finds the column of ANCHOR and adds OFFSET to
it as the final indentation of the current line.")

(defun treesit--indent-1 ()
  "Indent the current line.
Return (ANCHOR . OFFSET).  This function is used by
`treesit-indent' and `treesit-indent-region'."
  ;; Basically holds the common part between the two indent function.
  (let* ((bol (save-excursion
                (forward-line 0)
                (skip-chars-forward " \t")
                (point)))
         (local-parsers (treesit-local-parsers-at bol nil t))
         (smallest-node
          (cond ((car local-parsers)
                 (let ((local-parser (caar local-parsers))
                       (host-parser (cdar local-parsers)))
                   (if (eq (treesit-node-start
                            (treesit-parser-root-node local-parser))
                           bol)
                       (treesit-node-at bol host-parser)
                     (treesit-node-at bol local-parser))))
                ((null (treesit-parser-list)) nil)
                ((eq 1 (length (treesit-parser-list nil nil t)))
                 (treesit-node-at bol))
                ((treesit-language-at bol)
                 (treesit-node-at bol (treesit-language-at bol)))
                (t (treesit-node-at bol))))
         (root (treesit-parser-root-node
                (treesit-node-parser smallest-node)))
         (node (treesit-parent-while
                smallest-node
                (lambda (node)
                  (and (eq bol (treesit-node-start node))
                       (not (treesit-node-eq node root)))))))
    (let*
        ((parser (if smallest-node
                     (treesit-node-parser smallest-node)
                   nil))
         ;; NODE would be nil if BOL is on a whitespace.  In that case
         ;; we set PARENT to the "node at point", which would
         ;; encompass the whitespace.
         (parent (cond ((and node parser)
                        (treesit-node-parent node))
                       (t (treesit-node-on bol bol)))))
      (funcall treesit-indent-function node parent bol))))

(defun treesit-indent ()
  "Indent according to the result of `treesit-indent-function'."
  (treesit-update-ranges (line-beginning-position)
                         (line-end-position))
  ;; We don't return 'noindent even if no rules match, because
  ;; `indent-for-tab-command' tries to indent itself when we return
  ;; 'noindent, which leads to wrong indentation at times.
  (pcase-let* ((`(,anchor . ,offset) (treesit--indent-1)))
    (when (and anchor offset)
      (let ((col (+ (save-excursion
                      (goto-char anchor)
                      (current-column))
                    offset))
            (delta (- (point-max) (point))))
        (indent-line-to col)
        ;; Now point is at the end of indentation.  If we started
        ;; from within the line, go back to where we started.
        (when (> (- (point-max) delta) (point))
          (goto-char (- (point-max) delta)))))))

;; Batch size can't be too large, because we put markers on each
;; ANCHOR, so a batch size of 400 lines means 400 markers.
(defvar treesit--indent-region-batch-size 400
  "How many lines of indent value do we precompute.
In `treesit-indent-region' we indent in batches: precompute
indent for each line, apply them in one go, let parser reparse,
and do it again.  This way the parser doesn't need to unnecessarily
reparse after indenting every single line.")

(defun treesit-indent-region (beg end)
  "Indent the region between BEG and END.
Similar to `treesit-indent', but indent a region instead."
  (treesit-update-ranges beg end)
  ;; We indent `treesit--indent-region-batch-size' lines at a time, to
  ;; reduce the number of times the parser needs to re-parse.  In each
  ;; batch, we go through each line and calculate the anchor and
  ;; offset as usual, but instead of modifying the buffer, we save
  ;; these information in a vector.  Once we've collected ANCHOR and
  ;; OFFSET for each line in the batch, we go through each line again
  ;; and apply the changes.  Now that buffer is modified, we need to
  ;; reparse the buffer before continuing to indent the next batch.
  (let* ((meta-len 2)
         (vector-len (* meta-len treesit--indent-region-batch-size))
         ;; This vector saves the indent meta for each line in the
         ;; batch.  It is a vector [ANCHOR OFFSET ANCHOR OFFSET...].
         ;; ANCHOR is a marker on the anchor position, and OFFSET is
         ;; an integer.  ANCHOR and OFFSET are either both nil, or
         ;; both valid.
         (meta-vec (make-vector vector-len 0))
         (lines-left-to-move 0)
         (end (copy-marker end t))
         (idx 0)
         (starting-pos 0)
         (announce-progress (> (- end beg) 80000)))
    (save-excursion
      (goto-char beg)
      ;; First pass.  Go through each line and compute the
      ;; indentation.
      (while (and (eq lines-left-to-move 0) (< (point) end))
        (setq idx 0
              starting-pos (point))
        (while (and (eq lines-left-to-move 0)
                    (< idx treesit--indent-region-batch-size)
                    (< (point) end))
          (if (looking-at (rx (* whitespace) eol) t)
              ;; Unlike in `indent-line' where we sometimes pre-indent
              ;; an empty line, We don't indent empty lines in
              ;; `indent-region'.  Set ANCHOR and OFFSET to nil.
              (setf (aref meta-vec (* idx meta-len)) nil
                    (aref meta-vec (+ 1 (* idx meta-len))) nil)
            (pcase-let* ((`(,anchor . ,offset) (treesit--indent-1))
                         (marker (aref meta-vec (* idx meta-len))))
              (if (not (and anchor offset))
                  ;; No indent for this line, either...
                  (if (markerp marker)
                      (progn
                        ;; ... Set marker and offset to do a dummy
                        ;; indent, or...
                        (back-to-indentation)
                        (move-marker marker (point))
                        (setf (aref meta-vec (+ 1 (* idx meta-len))) 0))
                    ;; ...Set anchor to nil so no indent is performed.
                    (setf (aref meta-vec (* idx meta-len)) nil))
                ;; Set ANCHOR.
                (if (markerp marker)
                    (move-marker marker anchor)
                  (setf (aref meta-vec (* idx meta-len))
                        (copy-marker anchor t)))
                ;; SET OFFSET.
                (setf (aref meta-vec (+ 1 (* idx meta-len))) offset))))
          (cl-incf idx)
          (setq lines-left-to-move (forward-line 1)))
        ;; Now IDX = last valid IDX + 1.
        (goto-char starting-pos)
        ;; Second pass, go to each line and apply the indentation.
        (dotimes (jdx idx)
          (let ((anchor (aref meta-vec (* jdx meta-len)))
                (offset (aref meta-vec (+ 1 (* jdx meta-len)))))
            (when (and anchor offset)
              (let ((col (save-excursion
                           (goto-char anchor)
                           (+ offset (current-column)))))
                (indent-line-to col))))
          (forward-line 1))
        (when announce-progress
          (message "Indenting region...%s%%"
                   (/ (* (- (point) beg) 100) (- end beg)))))
      ;; Delete markers.
      (dotimes (idx treesit--indent-region-batch-size)
        (let ((marker (aref meta-vec (* idx meta-len))))
          (when (markerp marker)
            (move-marker marker nil))))
      (move-marker end nil))))

(defun treesit-simple-indent (node parent bol)
  "Calculate indentation according to `treesit-simple-indent-rules'.

BOL is the position of the first non-whitespace character on the
current line.  NODE is the largest node that starts at BOL,
PARENT is NODE's parent.

Return (ANCHOR . OFFSET) where ANCHOR is a node, OFFSET is the
indentation offset, meaning indent to align with ANCHOR and add
OFFSET."
  (if (null parent)
      (progn (when treesit--indent-verbose
               (message "PARENT is nil, not indenting"))
             (cons nil nil))
    (let* ((language (treesit-node-language parent))
           (rules (alist-get language
                             treesit-simple-indent-rules)))
      (cl-loop for rule in rules
               for pred = (nth 0 rule)
               for anchor = (nth 1 rule)
               for offset = (nth 2 rule)
               if (treesit--simple-indent-eval
                   (list pred node parent bol))
               do (when treesit--indent-verbose
                    (message "Matched rule: %S" rule))
               and
               return
               (let ((anchor-pos
                      (treesit--simple-indent-eval
                       (list anchor node parent bol)))
                     (offset-val
                      (cond ((numberp offset) offset)
                            ((and (symbolp offset)
                                  (boundp offset))
                             (symbol-value offset))
                            (t (treesit--simple-indent-eval
                                (list offset node parent bol))))))
                 (cons anchor-pos offset-val))
               finally return
               (progn (when treesit--indent-verbose
                        (message "No matched rule"))
                      (cons nil nil))))))

(defun treesit--read-major-mode ()
  "Read a major mode using completion.
Helper function to use in the `interactive' spec of `treesit-check-indent'."
  (let* ((default (and (symbolp major-mode) (symbol-name major-mode)))
	 (mode
	  (completing-read
	   (format-prompt "Target major mode" default)
	   obarray
	   (lambda (sym)
	     (and (string-suffix-p "-mode" (symbol-name sym))
		  (not (or (memq sym minor-mode-list)
                           (string-suffix-p "-minor-mode"
                                            (symbol-name sym))))))
	   nil nil nil default nil)))
    (cond
     ((equal mode "nil") nil)
     ((and (stringp mode) (fboundp (intern mode))) (intern mode))
     (t mode))))

(defun treesit-check-indent (mode)
  "Compare the current buffer with how major mode MODE would indent it."
  (interactive (list (treesit--read-major-mode)))
  (let ((source-buf (current-buffer)))
    (with-temp-buffer
      (insert-buffer-substring source-buf)
      (funcall mode)
      (indent-region (point-min) (point-max))
      (diff-buffers source-buf (current-buffer)))))

(defun treesit--indent-rules-optimize (rules)
  "Optimize simple indent RULES.
RULES should be a value suitable for
`treesit-simple-indent-rules'.  Return the optimized version of
RULES."
  ;; Right now this function just compiles queries.  It doesn't
  ;; byte-compile matchers and anchors because it doesn't make much
  ;; difference.
  (cl-loop for setting in rules
           for lang = (car setting)
           for indent-rules = (cdr setting)
           collect
           (cl-labels
               ;; Optimize a matcher or anchor.
               ((optimize-func (func)
                  (pcase func
                    (`(query ,qry)
                     (list 'query (treesit-query-compile lang qry)))
                    (`(and . ,fns)
                     (cons 'and (mapcar #'optimize-func fns)))
                    (`(or . ,fns)
                     (cons 'or (mapcar #'optimize-func fns)))
                    (_ func)))
                ;; Optimize a rule (MATCHER ANCHOR OFFSET).
                (optimize-rule (rule)
                  (let ((matcher (nth 0 rule))
                        (anchor (nth 1 rule))
                        (offset (nth 2 rule)))
                    (list (optimize-func matcher)
                          (optimize-func anchor)
                          offset))))
             (cons lang (mapcar #'optimize-rule indent-rules)))))

;;; Search

(defun treesit-search-forward-goto
    (node predicate &optional start backward all)
  "Search forward for a node and move to its end position.

Stop at the first node after NODE that matches PREDICATE.
PREDICATE can be either a regexp that matches against each node's
type case-insensitively, or a function that takes a node and
returns nil/non-nil for match/no match.

If a node matches, move to that node and return the node,
otherwise return nil.  If START is non-nil, stop at the
beginning rather than the end of a node.

This function guarantees that the matched node it returns makes
progress in terms of buffer position: the start/end position of
the returned node is always STRICTLY greater/less than that of
NODE.

BACKWARD and ALL are the same as in `treesit-search-forward'."
  (when-let* ((start-pos (if start
                             (treesit-node-start node)
                           (treesit-node-end node)))
              (current-pos start-pos))
    ;; When searching forward and stopping at beginnings, or search
    ;; backward stopping at ends, it is possible to "roll back" in
    ;; position.  Take three nodes N1, N2, N3 as an example, if we
    ;; start at N3, search for forward for beginning, and N1 matches,
    ;; we would stop at beg of N1, which is backwards!  So we skip N1
    ;; and keep going.
    ;;
    ;;   |<--------N1------->|
    ;;   |<--N2-->| |<--N3-->|
    (while (and node (if backward
                         (>= current-pos start-pos)
                       (<= current-pos start-pos)))
      (setq node (treesit-search-forward
                  node predicate backward all))
      (setq current-pos (if start
                            (treesit-node-start node)
                          (treesit-node-end node))))
    (cond
     ;; When there is a match and match made progress, go to the
     ;; result position.
     ((and node
           (if backward
               (< current-pos (point))
             (> current-pos (point))))
      (goto-char current-pos)))
    node))

(make-obsolete 'treesit-sexp-type-regexp
               "`treesit-sexp-type-regexp' will be removed soon, use `treesit-thing-settings' instead." "30.1")

(defvar-local treesit-sexp-type-regexp nil
  "A regexp that matches the node type of sexp nodes.

A sexp node is a node that is bigger than punctuation, and
delimits medium sized statements in the source code.  It is,
however, smaller in scope than sentences.  This is used by
`treesit-forward-sexp' and friends.")

(defun treesit-forward-sexp (&optional arg)
  "Tree-sitter implementation for `forward-sexp-function'.

ARG is described in the docstring of `forward-sexp-function'.

If point is inside a text environment where tree-sitter is not
supported, go forward a sexp using `forward-sexp-default-function'.
If point is inside code, use tree-sitter functions with the
following behavior.  If there are no further sexps to move across,
signal `scan-error' like `forward-sexp' does.  If point is already
at top-level, return nil without moving point.

What constitutes as text and source code sexp is determined
by `text' and `sexp' in `treesit-thing-settings'."
  (interactive "^p")
  (let ((arg (or arg 1))
        (pred (or treesit-sexp-type-regexp 'sexp))
        (node-at-point
         (treesit-node-at (point) (treesit-language-at (point)))))
    (or (when (and node-at-point
                   ;; Make sure point is strictly inside node.
                   (< (treesit-node-start node-at-point)
                      (point)
                      (treesit-node-end node-at-point))
                   (treesit-node-match-p node-at-point 'text t))
          (forward-sexp-default-function arg)
          t)
        (if (> arg 0)
            (treesit-end-of-thing pred (abs arg) 'restricted)
          (treesit-beginning-of-thing pred (abs arg) 'restricted))
        ;; If we couldn't move, we should signal an error and report
        ;; the obstacle, like `forward-sexp' does.  If we couldn't
        ;; find a parent, we simply return nil without moving point,
        ;; then functions like `up-list' will signal "at top level".
        (when-let* ((parent (treesit-thing-at (point) pred t))
                    (boundary (if (> arg 0)
                                  (treesit-node-child parent -1)
                                (treesit-node-child parent 0))))
          (signal 'scan-error (list "No more sexp to move across"
                                    (treesit-node-start boundary)
                                    (treesit-node-end boundary)))))))

(defun treesit-transpose-sexps (&optional arg)
  "Tree-sitter `transpose-sexps' function.
ARG is the same as in `transpose-sexps'.

Locate the node closest to POINT, and transpose that node with
its sibling node ARG nodes away.

Return a pair of positions as described by
`transpose-sexps-function' for use in `transpose-subr' and
friends."
  ;; First arrive at the right level at where the node at point is
  ;; considered a sexp. If sexp isn't defined, or we can't find any
  ;; node that's a sexp, use the node at point.
  (let* ((node (or (treesit-thing-at-point 'sexp 'nested)
                   (treesit-node-at (point))))
         (parent (treesit-node-parent node))
         (child (treesit-node-child parent 0 t)))
    (named-let loop ((prev child)
                     (next (treesit-node-next-sibling child t)))
      (when (and prev next)
        (if (< (point) (treesit-node-end next))
            (if (= arg -1)
                (cons (treesit-node-start prev)
                      (treesit-node-end prev))
              (when-let ((n (treesit-node-child
                             parent (+ arg (treesit-node-index prev t)) t)))
                (cons (treesit-node-end n)
                      (treesit-node-start n))))
          (loop (treesit-node-next-sibling prev t)
                (treesit-node-next-sibling next t)))))))

;;; Navigation, defun, things
;;
;; Emacs lets you define "things" by a regexp that matches the type of
;; a node, and here are some functions that lets you find the "things"
;; at/around point, navigate backward/forward a "thing", etc.
;;
;; The most obvious "thing" is a defun, and there are thin wrappers
;; around thing functions for defun for convenience.
;;
;; We have more command-like functions like:
;; - treesit-beginning-of-thing/defun
;; - treesit-end-of-thing/defun
;; - treesit-thing/defun-at-point
;;
;; And more generic functions like:
;; - treesit-thing-prev/next
;; - treesit-thing-at
;; - treesit-top-level-thing
;; - treesit-navigate-thing
;;
;; There are also some defun-specific functions, like
;; treesit-defun-name, treesit-add-log-current-defun.
;;
;; TODO: Integration with thing-at-point: once our thing interface is
;; stable.
;;
;; TODO: Integration with hideshow: I tried and failed, we need
;; SomeOne that understands hideshow to look at it.

(defvar-local treesit-defun-type-regexp nil
  "A regexp that matches the node type of defun nodes.
For example, \"(function|class)_definition\".

Sometimes not all nodes matched by the regexp are valid defuns.
In that case, set this variable to a cons cell of the
form (REGEXP . PRED), where PRED is a function that takes a
node (the matched node) and returns t if node is valid, or nil
for invalid node.

This is used by `treesit-beginning-of-defun' and friends.")

(defvar-local treesit-defun-tactic 'nested
  "Determines how Emacs treats nested defuns.
If the value is `top-level', Emacs only moves across top-level
defuns, if the value is `nested', Emacs recognizes nested defuns.")

(defvar-local treesit-defun-skipper #'treesit-default-defun-skipper
  "A function called after tree-sitter navigation moved a step.

It is called with no arguments.  By default, this function tries
to move to the beginning of a line, either by moving to the empty
newline after a defun, or the beginning of a defun.

If the value is nil, no skipping is performed.")

(defvar-local treesit-defun-name-function nil
  "A function that is called with a node and returns its defun name or nil.
If the node is a defun node, return the defun name, e.g., the
name of a function.  If the node is not a defun node, or the
defun node doesn't have a name, or the node is nil, return nil.")

(defvar-local treesit-add-log-defun-delimiter "."
  "The delimiter used to connect several defun names.
This is used in `treesit-add-log-current-defun'.")

(defun treesit-thing-definition (thing language)
  "Return the predicate for THING if it's defined for LANGUAGE.
A thing is considered defined if it has an entry in
`treesit-thing-settings'.

If LANGUAGE is nil, return the first definition for THING in
`treesit-thing-settings'."
  (if language
      (car (alist-get thing (alist-get language
                                       treesit-thing-settings)))
    (car (alist-get thing (mapcan (lambda (entry)
                                    (copy-tree (cdr entry)))
                                  treesit-thing-settings)))))

(defalias 'treesit-thing-defined-p #'treesit-thing-definition
  "Return non-nil if THING is defined.")

(defun treesit-beginning-of-thing (thing &optional arg tactic)
  "Like `beginning-of-defun', but generalized into things.

THING can be a thing defined in `treesit-thing-settings', which see,
or a predicate.  ARG is the same as in `beginning-of-defun'.

TACTIC determines how does this function move between things.  It
can be `nested', `top-level', `restricted', or nil.  `nested'
means normal nested navigation: try to move to siblings first,
and if there aren't enough siblings, move to the parent and its
siblings.  `top-level' means only consider top-level things, and
nested things are ignored.  `restricted' means movement is
restricted inside the thing that encloses POS (i.e., parent),
should there be one.  If omitted, TACTIC is considered to be
`nested'.

Return non-nil if successfully moved, nil otherwise."
  (pcase-let* ((arg (or arg 1))
               (dest (treesit-navigate-thing
                      (point) (- arg) 'beg thing tactic)))
    (when dest
      (goto-char dest))))

(defun treesit-end-of-thing (thing &optional arg tactic)
  "Like `end-of-defun', but generalized into things.

THING can be a thing defined in `treesit-thing-settings', which
see, or a predicate.  ARG is the same as in `end-of-defun'.

TACTIC determines how does this function move between things.  It
can be `nested', `top-level', `restricted', or nil.  `nested'
means normal nested navigation: try to move to siblings first,
and if there aren't enough siblings, move to the parent and its
siblings.  `top-level' means only consider top-level things, and
nested things are ignored.  `restricted' means movement is
restricted inside the thing that encloses POS (i.e., parent),
should there be one.  If omitted, TACTIC is considered to be
`nested'.

Return non-nil if successfully moved, nil otherwise."
  (pcase-let* ((arg (or arg 1))
               (dest (treesit-navigate-thing
                      (point) arg 'end thing tactic)))
    (when dest
      (goto-char dest))))

(defun treesit-beginning-of-defun (&optional arg)
  "Move backward to the beginning of a defun.

With argument ARG, do it that many times.  Negative ARG means
move forward to the ARGth following beginning of defun.

If search is successful, return t, otherwise return nil.

This is a tree-sitter equivalent of `beginning-of-defun'.
Behavior of this function depends on `treesit-defun-type-regexp'
and `treesit-defun-skipper'.  If `treesit-defun-type-regexp' is
not set, Emacs also looks for definition of defun in
`treesit-thing-settings'."
  (interactive "^p")
  (or (not (eq this-command 'treesit-beginning-of-defun))
      (eq last-command 'treesit-beginning-of-defun)
      (and transient-mark-mode mark-active)
      (push-mark))
  (let ((orig-point (point))
        (success nil)
        (pred (or treesit-defun-type-regexp 'defun)))
    (catch 'done
      (dotimes (_ 2)

        (when (treesit-beginning-of-thing pred arg treesit-defun-tactic)
          (when treesit-defun-skipper
            (funcall treesit-defun-skipper)
            (setq success t)))

        ;; If we end up at the same point, it means we went to the
        ;; next beg-of-defun, but defun skipper moved point back to
        ;; where we started, in this case we just move one step
        ;; further.
        (if (or (eq arg 0) (not (eq orig-point (point))))
            (throw 'done success)
          (setq arg (if (> arg 0) (1+ arg) (1- arg))))))))

(defun treesit-end-of-defun (&optional arg _)
  "Move forward to next end of defun.

With argument ARG, do it that many times.
Negative argument -N means move back to Nth preceding end of defun.

This is a tree-sitter equivalent of `end-of-defun'.  Behavior of
this function depends on `treesit-defun-type-regexp' and
`treesit-defun-skipper'.  If `treesit-defun-type-regexp' is not
set, Emacs also looks for definition of defun in
`treesit-thing-settings'."
  (interactive "^p\nd")
  (let ((orig-point (point))
        (pred (or treesit-defun-type-regexp 'defun)))
    (if (or (null arg) (= arg 0)) (setq arg 1))
    (or (not (eq this-command 'treesit-end-of-defun))
        (eq last-command 'treesit-end-of-defun)
        (and transient-mark-mode mark-active)
        (push-mark))
    (catch 'done
      (dotimes (_ 2) ; Not making progress is better than infloop.

        (when (treesit-end-of-thing pred arg treesit-defun-tactic)
          (when treesit-defun-skipper
            (funcall treesit-defun-skipper)))

        ;; If we end up at the same point, it means we went to the
        ;; prev end-of-defun, but defun skipper moved point back to
        ;; where we started, in this case we just move one step
        ;; further.
        (if (or (eq arg 0) (not (eq orig-point (point))))
            (throw 'done nil)
          (setq arg (if (> arg 0) (1+ arg) (1- arg))))))))

(make-obsolete 'treesit-text-type-regexp
               "`treesit-text-type-regexp' will be removed soon, use `treesit-thing-settings' instead." "30.1")

(defvar-local treesit-text-type-regexp "\\`comment\\'"
  "A regexp that matches the node type of textual nodes.

A textual node is a node that is not normal code, such as
comments and multiline string literals.  For example,
\"(line|block)_comment\" in the case of a comment, or
\"text_block\" in the case of a string.  This is used by
`prog-fill-reindent-defun' and friends.")

(make-obsolete 'treesit-sentence-type-regexp
               "`treesit-sentence-type-regexp' will be removed soon, use `treesit-thing-settings' instead." "30.1")

(defvar-local treesit-sentence-type-regexp nil
  "A regexp that matches the node type of sentence nodes.

A sentence node is a node that is bigger than a sexp, and
delimits larger statements in the source code.  It is, however,
smaller in scope than defuns.  This is used by
`treesit-forward-sentence' and friends.")

(defun treesit-forward-sentence (&optional arg)
  "Tree-sitter `forward-sentence-function' implementation.

ARG is the same as in `forward-sentence'.

If point is inside a text environment, go forward a prose
sentence using `forward-sentence-default-function'.  If point is
inside code, go forward a source code sentence.

What constitutes as text and source code sentence is determined
by `text' and `sentence' in `treesit-thing-settings'."
  (if (treesit-node-match-p (treesit-node-at (point)) 'text t)
      (funcall #'forward-sentence-default-function arg)
    (funcall
     (if (> arg 0) #'treesit-end-of-thing #'treesit-beginning-of-thing)
     'sentence (abs arg))))

(defun treesit-default-defun-skipper ()
  "Skips spaces after navigating a defun.
This function tries to move to the beginning of a line, either by
moving to the empty newline after a defun, or to the beginning of
the current line if the beginning of the defun is indented."
  ;; Moving forward, point at the end of a line and not already on an
  ;; empty line: go to BOL of the next line (which hopefully is an
  ;; empty line).
  (cond ((and (looking-at (rx (* (or " " "\t")) "\n"))
              (not (bolp)))
         (forward-line 1))
        ;; Moving backward, but there are some whitespace (and only
        ;; whitespace) between point and BOL: go back to BOL.
        ((looking-back (rx bol (+ (or " " "\t")))
                       (line-beginning-position))
         (beginning-of-line))))

(defun treesit--thing-sibling (pos thing prev)
  "Return the next or previous THING at POS.

If PREV is non-nil, return the previous THING.  It's guaranteed
that returned previous sibling's end <= POS, and returned next
sibling's beginning >= POS.

Return nil if no THING can be found.  THING should be a thing
defined in `treesit-thing-settings', or a predicate as described
in `treesit-thing-settings'."
  (let* ((cursor (treesit-node-at pos))
         (pos-pred (if prev
                       (lambda (n) (<= (treesit-node-end n) pos))
                     (lambda (n) (>= (treesit-node-start n) pos))))
         (iter-pred (lambda (node)
                      (and (treesit-node-match-p node thing t)
                           (funcall pos-pred node))))
         (sibling nil))
    (when cursor
      ;; Find the node just before/after POS to start searching.
      (save-excursion
        (while (and cursor (not (funcall pos-pred cursor)))
          (setq cursor (treesit-search-forward-goto
                        cursor "" prev prev t))))
      ;; Keep searching until we run out of candidates or found a
      ;; return value.
      (while (and cursor
                  (funcall pos-pred cursor)
                  (null sibling))
        (setq sibling (treesit-node-top-level cursor iter-pred t))
        (setq cursor (treesit-search-forward cursor thing prev prev)))
      sibling)))

(defun treesit-thing-prev (pos thing)
  "Return the previous THING at POS.

The returned node, if non-nil, must be before POS, i.e., its end
<= POS.

THING should be a thing defined in `treesit-thing-settings', or a
predicate as described in `treesit-thing-settings'."
  (treesit--thing-sibling pos thing t))

(defun treesit-thing-next (pos thing)
  "Return the next THING at POS.

The returned node, if non-nil, must be after POS, i.e., its
start >= POS.

THING should be a thing defined in `treesit-thing-settings', or a
predicate as described in `treesit-thing-settings'."
  (treesit--thing-sibling pos thing nil))

(defun treesit-thing-at (pos thing &optional strict)
  "Return the smallest THING enclosing POS.

The returned node, if non-nil, must enclose POS, i.e., its start
<= POS, its end > POS.  If STRICT is non-nil, the returned node's
start must < POS rather than <= POS.

THING should be a thing defined in `treesit-thing-settings', or
it can be a predicate described in `treesit-thing-settings'."
  (let* ((cursor (treesit-node-at pos))
         (iter-pred (lambda (node)
                      (and (treesit-node-match-p node thing t)
                           (if strict
                               (< (treesit-node-start node) pos)
                             (<= (treesit-node-start node) pos))
                           (< pos (treesit-node-end node))))))
    (treesit-parent-until cursor iter-pred t)))

;; The basic idea for nested defun navigation is that we first try to
;; move across sibling defuns in the same level, if no more siblings
;; exist, we move to parents's beg/end, rinse and repeat.  We never
;; move into a defun, only outwards.
;;
;; Let me describe roughly what does this function do: there are four
;; possible operations: prev-beg, next-end, prev-end, next-beg, and
;; each of (prev-sibling next-sibling and parent) could exist or not
;; exist.  So there are 4 times 8 = 32 situations.
;;
;; I'll only describe the situation when we go backward (prev-beg &
;; prev-end), and consider only prev-sibling & parent. Deriving the
;; reverse situations is left as an exercise for the reader.
;;
;; prev-beg (easy case):
;; 1. prev-sibling or parent exists
;;    -> go the prev-sibling/parent's beg
;;
;; prev-end (tricky):
;; 1. prev-sibling exists
;;    -> If we are already at prev-sibling's end, we need to go one
;;       step further, either to prev-prev-sibling's end, or parent's
;;       prev-sibling's end, etc.
;; 2. prev-sibling is nil but parent exists
;;    -> Obviously we don't want to go to parent's end, instead, we
;;       want to go to parent's prev-sibling's end.  Again, we recurse
;;       in the function to do that.
(defun treesit-navigate-thing (pos arg side thing &optional tactic recursing)
  "Navigate thing ARG steps from POS.

If ARG is positive, move forward that many steps, if negative,
move backward.  If SIDE is `beg', stop at the beginning of a
thing, if SIDE is `end', stop at the end.

This function doesn't actually move point, it just returns the
position it would move to.  If there aren't enough things to move
across, return nil.

THING can be a regexp, a predicate function, and more.  See
`treesit-thing-settings' for details.

TACTIC determines how does this function move between things.  It
can be `nested', `top-level', `restricted', or nil.  `nested'
means normal nested navigation: try to move to siblings first,
and if there aren't enough siblings, move to the parent and its
siblings.  `top-level' means only consider top-level things, and
nested things are ignored.  `restricted' means movement is
restricted inside the thing that encloses POS (i.e., parent),
should there be one.  If omitted, TACTIC is considered to be
`nested'.

RECURSING is an internal parameter, if non-nil, it means this
function is called recursively."
  (pcase-let*
      ((counter (abs arg))
       ;; Move POS to the beg/end of NODE.  If NODE is nil, terminate.
       ;; Return the position we moved to.
       (advance (lambda (node)
                  (let ((dest (pcase side
                                ('beg (treesit-node-start node))
                                ('end (treesit-node-end node)))))
                    (if (null dest)
                        (throw 'term nil)
                      dest)))))
    (catch 'term
      (while (> counter 0)
        (let ((prev (treesit-thing-prev pos thing))
              (next (treesit-thing-next pos thing))
              (parent (treesit-thing-at pos thing t)))
          (when (and parent prev
                     (not (treesit-node-enclosed-p prev parent)))
            (setq prev nil))
          (when (and parent next
                     (not (treesit-node-enclosed-p next parent)))
            (setq next nil))
          ;; When PARENT is nil, nested and top-level are the same, if
          ;; there is a PARENT, make PARENT to be the top-level parent
          ;; and pretend there is no nested PREV and NEXT.
          (when (and (eq tactic 'top-level)
                     parent)
            (setq parent (treesit-node-top-level parent thing t)
                  prev nil
                  next nil))
          ;; If TACTIC is `restricted', the implementation is simple.
          ;; In principle we don't go to parent's beg/end for
          ;; `restricted' tactic, but if the parent is a "leaf thing"
          ;; (doesn't have any child "thing" inside it), then we can
          ;; move to the beg/end of it (bug#68899).
          (if (eq tactic 'restricted)
              (setq pos (funcall
                         advance
                         (cond ((and (null next) (null prev)) parent)
                               ((> arg 0) next)
                               (t prev))))
            ;; For `nested', it's a bit more work:
            ;; Move...
            (if (> arg 0)
                ;; ...forward.
                (if (and (eq side 'beg)
                         ;; Should we skip the defun (recurse)?
                         (cond (next (and (not recursing) ; [1] (see below)
                                          (eq pos (funcall advance next))))
                               (parent t))) ; [2]
                    ;; Special case: go to next beg-of-defun, but point
                    ;; is already on beg-of-defun.  Set POS to the end
                    ;; of next-sib/parent defun, and run one more step.
                    ;; If there is a next-sib defun, we only need to
                    ;; recurse once, so we don't need to recurse if we
                    ;; are already recursing [1]. If there is no
                    ;; next-sib but a parent, keep stepping out
                    ;; (recursing) until we got out of the parents until
                    ;; (1) there is a next sibling defun, or (2) no more
                    ;; parents [2].
                    ;;
                    ;; If point on beg-of-defun but we are already
                    ;; recurring, that doesn't count as special case,
                    ;; because we have already made progress (by moving
                    ;; the end of next before recurring.)
                    (setq pos (or (treesit-navigate-thing
                                   (treesit-node-end (or next parent))
                                   1 'beg thing tactic t)
                                  (throw 'term nil)))
                  ;; Normal case.
                  (setq pos (funcall advance (or next parent))))
              ;; ...backward.
              (if (and (eq side 'end)
                       (cond (prev (and (not recursing)
                                        (eq pos (funcall advance prev))))
                             (parent t)))
                  ;; Special case: go to prev end-of-defun.
                  (setq pos (or (treesit-navigate-thing
                                 (treesit-node-start (or prev parent))
                                 -1 'end thing tactic t)
                                (throw 'term nil)))
                ;; Normal case.
                (setq pos (funcall advance (or prev parent))))))
          ;; A successful step! Decrement counter.
          (cl-decf counter))))
    ;; Counter equal to 0 means we successfully stepped ARG steps.
    (if (eq counter 0) pos nil)))

;; TODO: In corporate into thing-at-point.
(defun treesit-thing-at-point (thing tactic)
  "Return the THING at point, or nil if none is found.

THING can be a symbol, a regexp, a predicate function, and more;
see `treesit-thing-settings' for details.

Return the top-level THING if TACTIC is `top-level'; return the
smallest enclosing THING as POS if TACTIC is `nested'."

  (let ((node (treesit-thing-at (point) thing)))
    (if (eq tactic 'top-level)
        (treesit-node-top-level node thing t)
      node)))

(defun treesit-defun-at-point ()
  "Return the defun node at point, or nil if none is found.

Respects `treesit-defun-tactic': returns the top-level defun if it
is `top-level', otherwise return the immediate parent defun if it
is `nested'.

Return nil if `treesit-defun-type-regexp' isn't set and `defun'
isn't defined in `treesit-thing-settings'."
  (when (or treesit-defun-type-regexp (treesit-thing-defined-p 'defun))
    (treesit-thing-at-point
     (or treesit-defun-type-regexp 'defun) treesit-defun-tactic)))

(defun treesit-defun-name (node)
  "Return the defun name of NODE.

Return nil if there is no name, or if NODE is not a defun node,
or if NODE is nil.

If `treesit-defun-name-function' is nil, always return nil."
  (when treesit-defun-name-function
    (funcall treesit-defun-name-function node)))

(defun treesit-add-log-current-defun ()
  "Return the name of the defun at point.

Used for `add-log-current-defun-function'.

The delimiter between nested defun names is controlled by
`treesit-add-log-defun-delimiter'."
  (let ((node (treesit-defun-at-point))
        (name nil))
    (while node
      (when-let ((new-name (treesit-defun-name node)))
        (if name
            (setq name (concat new-name
                               treesit-add-log-defun-delimiter
                               name))
          (setq name new-name)))
      (setq node (treesit-node-parent node)))
    name))

;;; Imenu

(defvar treesit-simple-imenu-settings nil
  "Settings that configure `treesit-simple-imenu'.

It should be a list of (CATEGORY REGEXP PRED NAME-FN).

CATEGORY is the name of a category, like \"Function\", \"Class\",
etc.  REGEXP should be a regexp matching the type of nodes that
belong to CATEGORY.  PRED should be either nil or a function
that takes a node an the argument.  It should return non-nil if
the node is a valid node for CATEGORY, or nil if not.

CATEGORY could also be nil.  In that case the entries matched by
REGEXP and PRED are not grouped under CATEGORY.

NAME-FN should be either nil or a function that takes a defun
node and returns the name of that defun node.  If NAME-FN is nil,
`treesit-defun-name' is used.

`treesit-major-mode-setup' automatically sets up Imenu if this
variable is non-nil.")

(defun treesit--simple-imenu-1 (node pred name-fn)
  "Given a sparse tree, create an Imenu index.

NODE is a node in the tree returned by
`treesit-induce-sparse-tree' (not a tree-sitter node, its car is
a tree-sitter node).  Walk that tree and return an Imenu index.

Return a list of entries where each ENTRY has the form:

ENTRY := (NAME . MARKER)
       | (NAME . ((\" \" . MARKER)
                  ENTRY
                  ...)

PRED and NAME-FN are the same as described in
`treesit-simple-imenu-settings'.  NAME-FN computes NAME in an
ENTRY.  MARKER marks the start of each tree-sitter node."
  (let* ((ts-node (car node))
         (children (cdr node))
         (subtrees (mapcan (lambda (node)
                             (treesit--simple-imenu-1 node pred name-fn))
                           children))
         ;; The root of the tree could have a nil ts-node.
         (name (when ts-node
                 (or (if name-fn
                         (funcall name-fn ts-node)
                       (treesit-defun-name ts-node))
                     "Anonymous")))
         (marker (when ts-node
                   (set-marker (make-marker)
                               (treesit-node-start ts-node)))))
    (cond
     ;; The tree-sitter node in the root node of the tree returned by
     ;; `treesit-induce-sparse-tree' is often nil.
     ((null ts-node)
      subtrees)
     ;; This tree-sitter node is not a valid entry, skip it.
     ((and pred (not (funcall pred ts-node)))
      subtrees)
     ;; Non-leaf node, return a (list of) subgroup.
     (subtrees
      `((,name
         ,(cons " " marker)
         ,@subtrees)))
     ;; Leaf node, return a (list of) plain index entry.
     (t (list (cons name marker))))))

(defun treesit-simple-imenu ()
  "Return an Imenu index for the current buffer."
  (let ((root (treesit-buffer-root-node)))
    (mapcan (lambda (setting)
              (pcase-let ((`(,category ,regexp ,pred ,name-fn)
                           setting))
                (when-let* ((tree (treesit-induce-sparse-tree
                                   root regexp))
                            (index (treesit--simple-imenu-1
                                    tree pred name-fn)))
                  (if category
                      (list (cons category index))
                    index))))
            treesit-simple-imenu-settings)))

;;; Outline minor mode

(defvar-local treesit-outline-predicate nil
  "Predicate used to find outline headings in the syntax tree.
The predicate can be a function, a regexp matching node type,
and more; see docstring of `treesit-thing-settings'.
It matches the nodes located on lines with outline headings.
Intended to be set by a major mode.  When nil, the predicate
is constructed from the value of `treesit-simple-imenu-settings'
when a major mode sets it.")

(defun treesit-outline-predicate--from-imenu (node)
  ;; Return an outline searching predicate created from Imenu.
  ;; Return the value suitable to set `treesit-outline-predicate'.
  ;; Create this predicate from the value `treesit-simple-imenu-settings'
  ;; that major modes set to find Imenu entries.  The assumption here
  ;; is that the positions of Imenu entries most of the time coincide
  ;; with the lines of outline headings.  When this assumption fails,
  ;; you can directly set a proper value to `treesit-outline-predicate'.
  (seq-some
   (lambda (setting)
     (and (string-match-p (nth 1 setting) (treesit-node-type node))
          (or (null (nth 2 setting))
              (funcall (nth 2 setting) node))))
   treesit-simple-imenu-settings))

(defun treesit-outline-search (&optional bound move backward looking-at)
  "Search for the next outline heading in the syntax tree.
For BOUND, MOVE, BACKWARD, LOOKING-AT, see the descriptions in
`outline-search-function'."
  (if looking-at
      (when-let* ((node (or (treesit-thing-at (pos-eol) treesit-outline-predicate)
                            (treesit-thing-at (pos-bol) treesit-outline-predicate)))
                  (start (treesit-node-start node)))
        (eq (pos-bol) (save-excursion (goto-char start) (pos-bol))))

    (let* ((bob-pos
            ;; `treesit-navigate-thing' can't find a thing at bobp,
            ;; so use `looking-at' to match at bobp.
            (and (bobp) (treesit-outline-search bound move backward t) (point)))
           (pos
            ;; When function wants to find the current outline, point
            ;; is at the beginning of the current line.  When it wants
            ;; to find the next outline, point is at the second column.
            (unless bob-pos
              (if (eq (point) (pos-bol))
                  (if (bobp) (point) (1- (point)))
                (pos-eol))))
           (found (or bob-pos
                      (treesit-navigate-thing pos (if backward -1 1) 'beg
                                              treesit-outline-predicate))))
      (if found
          (if (or (not bound) (if backward (>= found bound) (<= found bound)))
              (progn
                (goto-char found)
                (goto-char (pos-bol))
                (set-match-data (list (point) (pos-eol)))
                t)
            (when move (goto-char bound))
            nil)
        (when move (goto-char (or bound (if backward (point-min) (point-max)))))
        nil))))

(defun treesit-outline-level ()
  "Return the depth of the current outline heading."
  (let* ((node (treesit-node-at (point) nil t))
         (level (if (treesit-node-match-p node treesit-outline-predicate)
                    1 0)))
    (while (setq node (treesit-parent-until node treesit-outline-predicate))
      (setq level (1+ level)))
    (if (zerop level) 1 level)))

;;; Activating tree-sitter

(defun treesit-ready-p (language &optional quiet)
  "Check whether tree-sitter is ready to be used for MODE and LANGUAGE.

LANGUAGE is the language symbol to check for availability.
It can also be a list of language symbols.

If tree-sitter is not ready, emit a warning and return nil.  If
the user has chosen to activate tree-sitter for LANGUAGE and
tree-sitter is ready, return non-nil.  If QUIET is t, don't emit
a warning in either case; if quiet is `message', display a message
instead of emitting a warning."
  (let ((language-list (if (consp language)
                           language
                         (list language)))
        msg)
    ;; Check for each condition and set MSG.
    (catch 'term
      (when (not (treesit-available-p))
        (setq msg (if (fboundp 'treesit-node-p)
                      ;; Windows loads tree-sitter dynamically.
                      "tree-sitter library is not available or failed to load"
                    "Emacs is not compiled with tree-sitter library"))
        (throw 'term nil))
      (when (> (position-bytes (max (point-min) (1- (point-max))))
               treesit-max-buffer-size)
        (setq msg "buffer larger than `treesit-max-buffer-size'")
        (throw 'term nil))
      (dolist (lang language-list)
        (pcase-let ((`(,available . ,err)
                     (treesit-language-available-p lang t)))
          (when (not available)
            (setq msg (format "language grammar for %s is unavailable (%s): %s"
                              lang (nth 0 err)
                              (string-join
                               (mapcar (lambda (x) (format "%s" x))
                                       (cdr err))
                               " ")))
            (throw 'term nil)))))
    ;; Decide if all conditions met and whether emit a warning.
    (if (not msg)
        t
      (setq msg (concat "Cannot activate tree-sitter, because " msg))
      (pcase quiet
        ('nil (display-warning 'treesit msg))
        ('message (message "%s" msg)))
      nil)))

(defun treesit-major-mode-setup ()
  "Activate tree-sitter to power major-mode features.

If `treesit-font-lock-settings' is non-nil, set up fontification
and enable `font-lock-mode'.

If `treesit-simple-indent-rules' is non-nil, set up indentation.

If `treesit-defun-type-regexp' is non-nil or `defun' is defined
in `treesit-thing-settings', set up `beginning-of-defun-function'
and `end-of-defun-function'.

If `treesit-defun-name-function' is non-nil, set up
`add-log-current-defun'.

If `treesit-simple-imenu-settings' is non-nil, set up Imenu.

If either `treesit-outline-predicate' or `treesit-simple-imenu-settings'
are non-nil, and Outline minor mode settings don't alreay exist, setup
Outline minor mode.

If `sexp', `sentence' are defined in `treesit-thing-settings',
enable tree-sitter navigation commands for them.

Make sure necessary parsers are created for the current buffer
before calling this function."
  (unless treesit-primary-parser
    (setq treesit-primary-parser (treesit--guess-primary-parser)))
  ;; Font-lock.
  (when treesit-font-lock-settings
    ;; `font-lock-mode' wouldn't set up properly if
    ;; `font-lock-defaults' is nil, see `font-lock-specified-p'.
    (setq-local font-lock-defaults
                '( nil nil nil nil
                   (font-lock-fontify-syntactically-function
                    . treesit-font-lock-fontify-region)))
    (treesit-font-lock-recompute-features)
    (add-hook 'pre-redisplay-functions #'treesit--pre-redisplay 0 t)
    (when treesit-primary-parser
      (treesit-parser-add-notifier
       treesit-primary-parser #'treesit--font-lock-mark-ranges-to-fontify)))
  ;; Syntax
  (add-hook 'syntax-propertize-extend-region-functions
            #'treesit--pre-syntax-ppss 0 t)
  ;; Indent.
  (when treesit-simple-indent-rules
    (setq-local treesit-simple-indent-rules
                (treesit--indent-rules-optimize
                 treesit-simple-indent-rules)))
  ;; Enable indent if simple indent rules are set, or the major mode
  ;; sets a custom indent function.
  (when (or treesit-simple-indent-rules
            (and (not (eq treesit-indent-function #'treesit-simple-indent))
                 treesit-indent-function))
    (setq-local indent-line-function #'treesit-indent)
    (setq-local indent-region-function #'treesit-indent-region))
  ;; Navigation.
  (when (or treesit-defun-type-regexp
            (treesit-thing-defined-p 'defun nil))
    (keymap-set (current-local-map) "<remap> <beginning-of-defun>"
                #'treesit-beginning-of-defun)
    (keymap-set (current-local-map) "<remap> <end-of-defun>"
                #'treesit-end-of-defun)
    ;; `end-of-defun' will not work completely correctly in nested
    ;; defuns due to its implementation.  However, many lisp programs
    ;; use `beginning/end-of-defun', so we should still set
    ;; `beginning/end-of-defun-function' so they still mostly work.
    ;; This is also what `cc-mode' does: rebind user commands and set
    ;; the variables.  In future we should update `end-of-defun' to
    ;; work with nested defuns.
    (setq-local beginning-of-defun-function #'treesit-beginning-of-defun)
    (setq-local end-of-defun-function #'treesit-end-of-defun))
  ;; Defun name.
  (when treesit-defun-name-function
    (setq-local add-log-current-defun-function
                #'treesit-add-log-current-defun))

  (when (treesit-thing-defined-p 'sexp nil)
    (setq-local forward-sexp-function #'treesit-forward-sexp)
    (setq-local transpose-sexps-function #'treesit-transpose-sexps))

  (when (treesit-thing-defined-p 'sentence nil)
    (setq-local forward-sentence-function #'treesit-forward-sentence))

  ;; Imenu.
  (when treesit-simple-imenu-settings
    (setq-local imenu-create-index-function
                #'treesit-simple-imenu))

  ;; Outline minor mode.
  (when (and (or treesit-outline-predicate treesit-simple-imenu-settings)
             (not (seq-some #'local-variable-p
                            '(outline-search-function
                              outline-regexp outline-level))))
    (unless treesit-outline-predicate
      (setq treesit-outline-predicate
            #'treesit-outline-predicate--from-imenu))
    (setq-local outline-search-function #'treesit-outline-search
                outline-level #'treesit-outline-level))

  ;; Remove existing local parsers.
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when-let ((parser (overlay-get ov 'treesit-parser)))
      (treesit-parser-delete parser)
      (delete-overlay ov))))

;;; Debugging

(defvar-local treesit--inspect-name nil
  "Used by `treesit-inspect-mode' to show node name in mode-line.")

(defun treesit-inspect-node-at-point (&optional arg)
  "Show information of the node at point.
If called interactively, show in echo area, otherwise set
`treesit--inspect-name' (which will appear in the mode-line
if `treesit-inspect-mode' is enabled).  Uses the first parser
in `treesit-parser-list'."
  (interactive "p")
  ;; NODE-LIST contains all the node that starts at point.
  (let* ((node-list
          (cl-loop for node = (treesit-node-at (point))
                   then (treesit-node-parent node)
                   while node
                   if (eq (treesit-node-start node)
                          (point))
                   collect node))
         (largest-node (car (last node-list)))
         (parent (treesit-node-parent largest-node))
         ;; node-list-ascending contains all the node bottom-up, then
         ;; the parent.
         (node-list-ascending
          (if (null largest-node)
              ;; If there are no nodes that start at point, just show
              ;; the node at point and its parent.
              (list (treesit-node-at (point))
                    (treesit-node-parent
                     (treesit-node-at (point))))
            (append node-list (list parent))))
         (name ""))
    ;; We draw nodes like (parent field-name: (node)) recursively,
    ;; so it could be (node1 field-name: (node2 field-name: (node3))).
    (dolist (node node-list-ascending)
      (setq
       name
       (concat
        (if (treesit-node-field-name node)
            (format " %s: " (treesit-node-field-name node))
          " ")
        (if (treesit-node-check node 'named) "(" "\"")
        (propertize (or (treesit-node-type node) "N/A")
                    'face
                    (if (treesit-node-eq node largest-node)
                        'bold nil))
        name
        (if (treesit-node-check node 'named) ")" "\""))))
    ;; Escape the percent character for mode-line. (Bug#65540)
    (setq treesit--inspect-name (string-replace "%" "%%" name))
    (force-mode-line-update)
    (when arg
      (if node-list
          (message "%s" treesit--inspect-name)
        (message "No node at point")))))

(define-minor-mode treesit-inspect-mode
  "Minor mode that displays in the mode-line the node which starts at point.

When this mode is enabled, the mode-line displays

    PARENT FIELD-NAME: (NODE FIELD-NAME: (CHILD (...)))

where NODE, CHILD, etc, are nodes which begin at point.  PARENT
is the parent of NODE.  NODE is displayed in bold typeface.
FIELD-NAMEs are field names of NODE and CHILD, etc (see Info
node `(elisp)Language Grammar', heading \"Field names\").

If no node starts at point, i.e., point is in the middle of a
node, then the mode line displays the earliest node that spans point,
and its immediate parent.

This minor mode doesn't create parsers on its own.  It uses the first
parser in `treesit-parser-list'."
  :lighter nil
  (if treesit-inspect-mode
      (progn
        (add-hook 'post-command-hook
                  #'treesit-inspect-node-at-point 0 t)
        (add-to-list 'mode-line-misc-info
                     '(:eval treesit--inspect-name)))
    (remove-hook 'post-command-hook
                 #'treesit-inspect-node-at-point t)
    (setq mode-line-misc-info
          (remove '(:eval treesit--inspect-name)
                  mode-line-misc-info))))

(defun treesit-query-validate (language query)
  "Check if QUERY is valid for LANGUAGE.
If QUERY is invalid, display the query in a popup buffer, jump
to the offending pattern and highlight the pattern."
  (cl-assert (or (consp query) (stringp query)))
  (let ((buf (get-buffer-create "*tree-sitter check query*")))
    (with-temp-buffer
      (treesit-parser-create language)
      (condition-case err
          (progn (treesit-query-capture language query)
                 (message "QUERY is valid"))
        (treesit-query-error
         (with-current-buffer buf
           (let* ((data (cdr err))
                  (message (nth 0 data))
                  (start (nth 1 data))
                  (inhibit-read-only t))
             (erase-buffer)
             (insert (if (stringp query)
                         query
                       (treesit-query-expand query)))
             (goto-char start)
             (search-forward " " nil t)
             (put-text-property start (point) 'face 'error)
             (message "%s" (buffer-substring start (point)))
             (goto-char (point-min))
             (insert (format "%s: %d\n" message start))
             (forward-char start)))
         (pop-to-buffer buf)
         (view-mode))))))

;;; Explorer

(defface treesit-explorer-anonymous-node
  (let ((display t)
        (atts '(:inherit shadow)))
    `((,display . ,atts)))
  "Face for anonymous nodes in tree-sitter explorer.")

(defface treesit-explorer-field-name
  (let ((display t)
        (atts nil))
    `((,display . ,atts)))
  "Face for field names in tree-sitter explorer.")

(defvar-local treesit--explorer-buffer nil
  "Buffer used to display the syntax tree.")

(defvar-local treesit--explorer-source-buffer nil
  "Source buffer corresponding to the playground buffer.")

(defvar-local treesit--explorer-language nil
  "The language used in the playground.")

(defvar-local treesit--explorer-refresh-timer nil
  "Timer for refreshing the syntax tree buffer.")

(defvar-local treesit--explorer-highlight-overlay nil
  "Overlay used to highlight in syntax tree and source buffer.")

(defvar-local treesit--explorer-last-node nil
  "Last top-level node used to generate syntax tree.")

(defvar treesit-explore-mode)

(defun treesit--explorer--nodes-to-highlight (language)
  "Return nodes for LANGUAGE covered in region.
This function tries to return the largest node possible.  If the
region covers exactly one node, that node is returned (in a
list).  If the region covers more than one node, two nodes are
returned: the very first one in the region and the very last one
in the region."
  (let* ((beg (region-beginning))
         (end (region-end))
         (node (treesit-node-on beg end language))
         (node (or (treesit-parent-while
                    node
                    (lambda (n)
                      (<= beg (treesit-node-start n)
                          (treesit-node-end n) end)))
                   node)))
    ;; If NODE is completely contained in the region, return NODE,
    ;; otherwise return its children that are in the region.
    (if (<= beg (treesit-node-start node)
            (treesit-node-end node) end)
        (list node)
      (list (treesit-node-at beg)
            (treesit-search-forward
             (treesit-node-at end)
             (lambda (n)
               (<= (treesit-node-end n) end))
             t t)))))

(defun treesit--explorer-refresh ()
  "Update the syntax tree buffer."
  (when (and treesit-explore-mode
             (buffer-live-p treesit--explorer-buffer))
    (let* ((root (treesit-node-on
                  (window-start) (window-end) treesit--explorer-language))
           ;; Only highlight the current top-level construct.
           ;; Highlighting the whole buffer is slow and unnecessary.
           ;; But if the buffer is small (ie, used in playground
           ;; style), just highlight the whole buffer.
           (top-level (if (< (buffer-size) 4000)
                          root
                        (treesit-node-first-child-for-pos
                         root (if (eolp)
                                  (max (point-min) (1- (point)))
                                (point))
                         t)))
           ;; Only highlight node when region is active, if we
           ;; highlight node at point the syntax tree is too jumpy.
           (nodes-hl
            (when (region-active-p)
              (treesit--explorer--nodes-to-highlight
               treesit--explorer-language)))
           ;; If we didn't edit the buffer nor change the top-level
           ;; node, don't redraw the whole syntax tree.
           (highlight-only (treesit-node-eq
                            top-level treesit--explorer-last-node))
           (source-buffer (current-buffer)))
      (setq-local treesit--explorer-last-node top-level)
      (with-current-buffer treesit--explorer-buffer
        (let ((inhibit-read-only t))
          (setq-local treesit--explorer-source-buffer source-buffer)
          ;; Redraw the syntax tree or just rehighlight the focused
          ;; node.
          (when (and top-level (not highlight-only))
            (erase-buffer)
            (treesit--explorer-draw-node top-level))
          (when-let ((pos (treesit--explorer-highlight-node nodes-hl))
                     (window (get-buffer-window
                              treesit--explorer-buffer)))
            (if highlight-only
                (goto-char pos)
              ;; If HIGHLIGHT-ONLY is nil, we erased the buffer and
              ;; re-inserted text, scroll down from the very top until
              ;; we can see the highlighted node.
              (goto-char (point-min))
              (while (and (null (pos-visible-in-window-p pos window))
                          (= (forward-line 4) 0))
                (set-window-start window (point))))
            (set-window-point window pos)))))))

(defun treesit--explorer-post-command (&rest _)
  "Post-command function that runs in the source buffer."
  (when treesit-explore-mode
    (when treesit--explorer-highlight-overlay
      (delete-overlay treesit--explorer-highlight-overlay))
    (when treesit--explorer-refresh-timer
      (cancel-timer treesit--explorer-refresh-timer))
    (setq-local treesit--explorer-refresh-timer
                (run-with-timer 0.1 nil #'treesit--explorer-refresh))))

(defun treesit--explorer-jump (button)
  "Mark the original text corresponding to BUTTON."
  (when (and (derived-mode-p 'treesit--explorer-tree-mode)
             (buffer-live-p treesit--explorer-source-buffer))
    (with-current-buffer treesit--explorer-source-buffer
      (let ((start (button-get button 'node-start))
            (end (button-get button 'node-end)))
        (when treesit--explorer-highlight-overlay
          (delete-overlay treesit--explorer-highlight-overlay))
        (setq-local treesit--explorer-highlight-overlay
                    (make-overlay start end nil t nil))
        (overlay-put treesit--explorer-highlight-overlay
                     'face 'highlight)))))

(defun treesit--explorer-highlight-node (nodes)
  "Highlight nodes in NODES in the syntax tree buffer.
Return the start of the syntax tree text corresponding to NODE."
  (when treesit--explorer-highlight-overlay
    (delete-overlay treesit--explorer-highlight-overlay))
  (let ((start-node (car nodes))
        (end-node (car (last nodes)))
        start end)
    (when (and start-node end-node)
      (cl-loop for ov in (overlays-in (point-min) (point-max))
               while (or (null start) (null end))
               if (treesit-node-eq start-node
                                   (overlay-get ov 'treesit-node))
               do (setq start (overlay-start ov))
               if (treesit-node-eq end-node (overlay-get ov 'treesit-node))
               do (setq end (overlay-end ov)))
      (when (and start end)
        (setq-local treesit--explorer-highlight-overlay
                    (make-overlay start end))
        (overlay-put treesit--explorer-highlight-overlay
                     'face 'highlight)
        start))))

(defun treesit--explorer-draw-node (node)
  "Draw the syntax tree of NODE.

When this function is called, point should be at the position
where the node should start.  When this function returns, it
leaves point at the end of the last line of NODE."
  (let* ((type (treesit-node-type node))
         (field-name (treesit-node-field-name node))
         (children (treesit-node-children node))
         (named (treesit-node-check node 'named))
         ;; Column number of the start of the field-name, aka start of
         ;; the whole node.
         (before-field-column (current-column))
         ;; Column number after the field-name.
         after-field-column
         ;; Column number after the type.
         after-type-column
         ;; Are all children suitable for inline?
         (all-children-inline
          (eq 0 (apply #'+ (mapcar #'treesit-node-child-count children))))
         ;; If the child is the first child, we can inline, if the
         ;; previous child is suitable for inline, this child can
         ;; inline, if the previous child is not suitable for inline,
         ;; this child cannot inline.
         (can-inline t)
         ;; The beg and end of this node.
         beg end)
    (when treesit--explorer-highlight-overlay
      (delete-overlay treesit--explorer-highlight-overlay))

    (setq beg (point))
    ;; Draw field name.  If all children are suitable for inline, we
    ;; draw everything in one line, other wise draw field name and the
    ;; rest of the node in two lines.
    (when field-name
      (insert (propertize (concat field-name ": ")
                          'face 'treesit-explorer-field-name))
      (when (and children (not all-children-inline))
        (insert "\n")
        (indent-to-column (1+ before-field-column))))
    (setq after-field-column (current-column))

    ;; Draw type.
    (if named
        (progn
          (insert "(")
          (insert-text-button
           type 'action #'treesit--explorer-jump
           'follow-link t
           'node-start (treesit-node-start node)
           'node-end (treesit-node-end node)))
      (pcase type
        ("\n" (insert "\\n"))
        ("\t" (insert "\\t"))
        (" " (insert "SPC"))
        (_ (insert type))))
    (setq after-type-column (current-column))

    ;; Draw children.
    (dolist (child children)
      ;; If a child doesn't have children, it is suitable for inline.
      (let ((draw-inline (eq 0 (treesit-node-child-count child)))
            (children-indent (1+ after-field-column)))
        (while
            ;; This form returns t if it wants to run another
            ;; iteration, returns nil if it wants to stop.
            (if (and draw-inline can-inline)
                ;; Draw children on the same line.
                (let ((inline-beg (point)))
                  (insert " ")
                  (treesit--explorer-draw-node child)
                  ;; If we exceeds window width, draw on the next line.
                  (if (< (current-column) (window-width))
                      nil
                    (delete-region inline-beg (point))
                    (setq draw-inline nil
                          children-indent (1+ after-type-column))
                    t))
              ;; Draw children on the new line.
              (insert "\n")
              (indent-to-column children-indent)
              (treesit--explorer-draw-node child)
              nil))
        (setq can-inline draw-inline)))

    ;; Done drawing children, draw the ending paren.
    (when named (insert ")"))
    (setq end (point))

    ;; Associate the text with NODE, so we can later find a piece of
    ;; text by a node.
    (let ((ov (make-overlay beg end)))
      (overlay-put ov 'treesit-node node)
      (overlay-put ov 'evaporate t)
      (when (not named)
        (overlay-put ov 'face 'treesit-explorer-anonymous-node)))))

(defun treesit--explorer-kill-explorer-buffer ()
  "Kill the explorer buffer of this buffer."
  (when (buffer-live-p treesit--explorer-buffer)
    (kill-buffer treesit--explorer-buffer)))

(define-derived-mode treesit--explorer-tree-mode special-mode
  "TS Explorer"
  "Mode for displaying syntax trees for `treesit-explore-mode'."
  nil)

(define-minor-mode treesit-explore-mode
  "Enable exploring the current buffer's syntax tree.
Pops up a window showing the syntax tree of the source in the
current buffer in real time.  The corresponding node enclosing
the text in the active region is highlighted in the explorer
window."
  :lighter " TSexplore"
  (if treesit-explore-mode
      (let ((language
             (intern (completing-read
                      "Language: "
                      (cl-remove-duplicates
                       (mapcar #'treesit-parser-language
                               (treesit-parser-list nil nil t)))))))
        (if (not (treesit-language-available-p language))
            (user-error "Cannot find tree-sitter grammar for %s: %s"
                        language (cdr (treesit-language-available-p
                                       language t)))
          ;; Create explorer buffer.
          (unless (buffer-live-p treesit--explorer-buffer)
            (setq-local treesit--explorer-buffer
                        (get-buffer-create
                         (format "*tree-sitter explorer for %s*"
                                 (buffer-name))))
            (setq-local treesit--explorer-language language)
            (with-current-buffer treesit--explorer-buffer
              (treesit--explorer-tree-mode)))
          (display-buffer treesit--explorer-buffer
                          (cons nil '((inhibit-same-window . t))))
          (setq-local treesit--explorer-last-node nil)
          (treesit--explorer-refresh)
          ;; Set up variables and hooks.
          (add-hook 'post-command-hook
                    #'treesit--explorer-post-command 0 t)
          (add-hook 'kill-buffer-hook
                    #'treesit--explorer-kill-explorer-buffer 0 t)
          ;; Tell `desktop-save' to not save explorer buffers.
          (when (boundp 'desktop-modes-not-to-save)
            (unless (memq 'treesit--explorer-tree-mode
                          desktop-modes-not-to-save)
              (push 'treesit--explorer-tree-mode
                    desktop-modes-not-to-save)))))
    ;; Turn off explore mode.
    (remove-hook 'post-command-hook
                 #'treesit--explorer-post-command t)
    (remove-hook 'post-command-hook
                 #'treesit--explorer-kill-explorer-buffer t)
    (treesit--explorer-kill-explorer-buffer)))

;;; Install & build language grammar

(defvar treesit-language-source-alist nil
  "Configuration for downloading and installing tree-sitter language grammars.

The value should be an alist where each element has the form

    (LANG . (URL REVISION SOURCE-DIR CC C++))

Only LANG and URL are mandatory.  LANG is the language symbol.
URL is the URL of the grammar's Git repository or a directory
where the repository has been cloned.

REVISION is the Git tag or branch of the desired version,
defaulting to the latest default branch.

SOURCE-DIR is the relative subdirectory in the repository in which
the grammar's parser.c file resides, defaulting to \"src\".

CC and C++ are C and C++ compilers, defaulting to \"cc\" and
\"c++\", respectively.")

(defun treesit--install-language-grammar-build-recipe (lang)
  "Interactively produce a download/build recipe for LANG and return it.
See `treesit-language-source-alist' for details."
  (when (y-or-n-p (format "There is no recipe for %s, do you want to build it interactively?" lang))
    (cl-labels ((empty-string-to-nil (string)
                  (if (equal string "") nil string)))
      (list
       lang
       (let ((repo-default (format "https://github.com/tree-sitter/tree-sitter-%s" lang)))
         (read-string
          "Enter the URL of the Git repository of the language grammar: "
          (and (treesit--check-repo-url repo-default) repo-default)))
       (empty-string-to-nil
        (read-string
         "Enter the tag or branch (default: default branch): "))
       (empty-string-to-nil
        (read-string
         "Enter the subdirectory in which the parser.c file resides (default: \"src\"): "))
       (empty-string-to-nil
        (read-string
         "Enter the C compiler to use (default: auto-detect): "))
       (empty-string-to-nil
        (read-string
         "Enter the C++ compiler to use (default: auto-detect): "))))))

(defun treesit--check-repo-url (url)
  (defvar url-request-method)
  (let ((url-request-method "HEAD"))
    (let ((buffer (condition-case nil (url-retrieve-synchronously url t t)
                    (file-error nil))))
      (and buffer
           (eql
            (buffer-local-value 'url-http-response-status buffer)
            200)))))

(defvar treesit--install-language-grammar-out-dir-history nil
  "History for OUT-DIR for `treesit-install-language-grammar'.")

;;;###autoload
(defun treesit-install-language-grammar (lang &optional out-dir)
  "Build and install the tree-sitter language grammar library for LANG.

Interactively, if `treesit-language-source-alist' doesn't already
have data for building the grammar for LANG, prompt for its
repository URL and the C/C++ compiler to use.  The recipe built
by the prompts are saved for the current session if the
installation is successful and the grammar is loadable.

This command requires Git, a C compiler and (sometimes) a C++ compiler,
and the linker to be installed and on PATH.  It also requires that the
recipe for LANG exists in `treesit-language-source-alist'.

See `exec-path' for the current path where Emacs looks for
executable programs, such as the C/C++ compiler and linker.

Interactively, prompt for the directory in which to install the
compiled grammar files.  Non-interactively, use OUT-DIR; if it's
nil, the grammar is installed to the standard location, the
\"tree-sitter\" directory under `user-emacs-directory'."
  (interactive (list (intern
                      (completing-read
                       "Language: "
                       (mapcar #'car treesit-language-source-alist)))
                     'interactive))
  (when-let ((recipe
              (or (assoc lang treesit-language-source-alist)
                  (if (eq out-dir 'interactive)
                      (treesit--install-language-grammar-build-recipe
                       lang)
                    (signal 'treesit-error `("Cannot find recipe for this language" ,lang)))))
             (default-out-dir
              (or (car treesit--install-language-grammar-out-dir-history)
                  (locate-user-emacs-file "tree-sitter")))
             (out-dir
              (if (eq out-dir 'interactive)
                  (read-string
                   (format "Install to (default: %s): "
                           default-out-dir)
                   nil
                   'treesit--install-language-grammar-out-dir-history
                   default-out-dir)
                ;; When called non-interactively, OUT-DIR should
                ;; default to DEFAULT-OUT-DIR.
                (or out-dir default-out-dir))))
    (condition-case err
        (progn
          (apply #'treesit--install-language-grammar-1
                 (cons out-dir recipe))

          ;; Check that the installed language grammar is loadable.
          (pcase-let ((`(,available . ,err)
                       (treesit-language-available-p lang t)))
            (if (not available)
                (display-warning
                 'treesit
                 (format "The installed language grammar for %s cannot be located or has problems (%s): %s"
                         lang (nth 0 err)
                         (string-join
                          (mapcar (lambda (x) (format "%s" x))
                                  (cdr err))
                          " ")))
              ;; If success, Save the recipe for the current session.
              (setf (alist-get lang treesit-language-source-alist)
                    (cdr recipe)))))
      (error
       (display-warning
        'treesit
        (format "Error encountered when installing language grammar: %s"
                err))))))

(defun treesit--call-process-signal (&rest args)
  "Run `call-process' with ARGS.
If it returns anything but 0, signal an error.  Use the buffer
content as signal data, and erase buffer afterwards."
  (unless (eq 0 (apply #'call-process args))
    (signal 'treesit-error (list "Command:"
                                 (string-join (cons (car args)
                                                    (nthcdr 4 args))
                                              " ")
                                 "Error output:"
                                 (buffer-string)))
    (erase-buffer)))

(defun treesit--git-checkout-branch (repo-dir revision)
  "Checkout REVISION in a repo located in REPO-DIR."
  (treesit--call-process-signal
   "git" nil t nil "-C" repo-dir "checkout" revision))

(defun treesit--git-clone-repo (url revision workdir)
  "Clone repo pointed by URL at commit REVISION to WORKDIR.

REVISION may be nil, in which case the cloned repo will be at its
default branch."
  (message "Cloning repository")
  ;; git clone xxx --depth 1 --quiet [-b yyy] workdir
  (if revision
      (treesit--call-process-signal
       "git" nil t nil "clone" url "--depth" "1" "--quiet"
       "-b" revision workdir)
    (treesit--call-process-signal
     "git" nil t nil "clone" url "--depth" "1" "--quiet"
     workdir)))

(defun treesit--install-language-grammar-1
    (out-dir lang url &optional revision source-dir cc c++)
  "Install and compile a tree-sitter language grammar library.

OUT-DIR is the directory to put the compiled library file.  If it
is nil, the \"tree-sitter\" directory under user's Emacs
configuration directory is used (and automatically created if it
does not exist).

For LANG, URL, REVISION, SOURCE-DIR, GRAMMAR-DIR, CC, C++, see
`treesit-language-source-alist'.  If anything goes wrong, this
function signals an error."
  (let* ((lang (symbol-name lang))
         (maybe-repo-dir (expand-file-name url))
         (url-is-dir (file-accessible-directory-p maybe-repo-dir))
         (default-directory (make-temp-file "treesit-workdir" t))
         (workdir (if url-is-dir
                      maybe-repo-dir
                    (expand-file-name "repo")))
         (source-dir (expand-file-name (or source-dir "src") workdir))
         (cc (or cc (seq-find #'executable-find '("cc" "gcc" "c99"))
                 ;; If no C compiler found, just use cc and let
                 ;; `call-process' signal the error.
                 "cc"))
         (c++ (or c++ (seq-find #'executable-find '("c++" "g++"))
                  "c++"))
         (soext (or (car dynamic-library-suffixes)
                    (signal 'treesit-error '("Emacs cannot figure out the file extension for dynamic libraries for this system, because `dynamic-library-suffixes' is nil"))))
         (out-dir (or (and out-dir (expand-file-name out-dir))
                      (locate-user-emacs-file "tree-sitter")))
         (lib-name (concat "libtree-sitter-" lang soext)))
    (unwind-protect
        (with-temp-buffer
          (if url-is-dir
              (when revision
                (treesit--git-checkout-branch workdir revision))
            (treesit--git-clone-repo url revision workdir))
          ;; We need to go into the source directory because some
          ;; header files use relative path (#include "../xxx").
          ;; cd "${sourcedir}"
          (setq default-directory source-dir)
          (message "Compiling library")
          ;; cc -fPIC -c -I. parser.c
          (treesit--call-process-signal
           cc nil t nil "-fPIC" "-c" "-I." "parser.c")
          ;; cc -fPIC -c -I. scanner.c
          (when (file-exists-p "scanner.c")
            (treesit--call-process-signal
             cc nil t nil "-fPIC" "-c" "-I." "scanner.c"))
          ;; c++ -fPIC -I. -c scanner.cc
          (when (file-exists-p "scanner.cc")
            (treesit--call-process-signal
             c++ nil t nil "-fPIC" "-c" "-I." "scanner.cc"))
          ;; cc/c++ -fPIC -shared *.o -o "libtree-sitter-${lang}.${soext}"
          (apply #'treesit--call-process-signal
                 (if (file-exists-p "scanner.cc") c++ cc)
                 nil t nil
                 (if (eq system-type 'cygwin)
                     `("-shared" "-Wl,-dynamicbase"
                       ,@(directory-files
                          default-directory nil
                          (rx bos (+ anychar) ".o" eos))
                       "-o" ,lib-name)
                   `("-fPIC" "-shared"
                     ,@(directory-files
                        default-directory nil
                        (rx bos (+ anychar) ".o" eos))
                     "-o" ,lib-name)))
          ;; Copy out.
          (unless (file-exists-p out-dir)
            (make-directory out-dir t))
          (let* ((library-fname (expand-file-name lib-name out-dir))
                 (old-fname (concat library-fname ".old")))
            ;; Rename the existing shared library, if any, then
            ;; install the new one, and try deleting the old one.
            ;; This is for Windows systems, where we cannot simply
            ;; overwrite a DLL that is being used.
            (if (file-exists-p library-fname)
                (rename-file library-fname old-fname t))
            (copy-file lib-name (file-name-as-directory out-dir) t t)
            ;; Ignore errors, in case the old version is still used.
            (ignore-errors (delete-file old-fname)))
          (message "Library installed to %s/%s" out-dir lib-name))
      ;; Remove workdir if it's not a repo owned by user and we
      ;; managed to create it in the first place.
      (when (and (not url-is-dir) (file-exists-p workdir))
        (delete-directory workdir t)))))

;;; Etc

(declare-function find-library-name "find-func.el")
(defun treesit--check-manual-coverage ()
  "Print tree-sitter functions missing from the manual in message buffer."
  (interactive)
  (require 'find-func)
  (let ((functions-in-source
         (with-temp-buffer
           (insert-file-contents (find-library-name "treesit"))
           (cl-remove-if
            (lambda (name) (string-search "treesit--" name))
            (cl-sort
             (save-excursion
               (goto-char (point-min))
               (cl-loop while (re-search-forward
                               "^(defun \\([^ ]+\\)" nil t)
                        collect (match-string-no-properties 1)))
             #'string<))))
        (functions-in-manual
         (with-temp-buffer
           (insert-file-contents (expand-file-name
                                  "doc/lispref/parsing.texi"
                                  source-directory))
           (insert-file-contents (expand-file-name
                                  "doc/lispref/modes.texi"
                                  source-directory))
           (cl-sort
            (save-excursion
              (goto-char (point-min))
              (cl-loop while (re-search-forward
                              "^@defun \\([^ ]+\\)" nil t)
                       collect (match-string-no-properties 1)))
            #'string<))))
    (message "Missing: %s"
             (string-join
              (cl-remove-if
               (lambda (name) (member name functions-in-manual))
               functions-in-source)
              "\n"))))

;;; Shortdocs

(defun treesit--generate-shortdoc-examples ()
  "Generate examples for shortdoc."
  (with-temp-buffer
    (let (node parent)
      (insert "int c = 0;")
      (print (treesit-parser-create 'c))
      (print (treesit-parser-list))
      (goto-char (point-min))
      (print (setq node (treesit-node-at (point))))
      (print (setq parent (treesit-node-parent node)))
      (print (treesit-node-children parent))
      (print (treesit-node-next-sibling node))
      (print (treesit-node-child-by-field-name parent "declarator"))
      nil)))

(define-short-documentation-group treesit

  "Parsers"
  (treesit-parser-create
   :no-eval (treesit-parser-create 'c)
   :eg-result-string "#<treesit-parser for c>")
  (treesit-parser-delete
   :no-value (treesit-parser-delete parser))
  (treesit-parser-list
   :no-eval (treesit-parser-list)
   :eg-result-string "(#<treesit-parser for c>)")
  (treesit-parser-buffer
   :no-eval (treesit-parser-buffer parser)
   :eg-result-string "#<buffer xdisp.c>")
  (treesit-parser-language
   :no-eval (treesit-parser-language parser)
   :eg-result c)
  (treesit-parser-add-notifier)
  (treesit-parser-remove-notifier)
  (treesit-parser-notifiers
   :no-eval (treesit-parser-notifiers parser)
   :eg-result (function1 function2 function3))


  "Parser ranges"
  (treesit-parser-set-included-ranges
   :no-value (treesit-parser-set-included-ranges parser '((1 . 4) (5 . 8))))
  (treesit-parser-included-ranges
   :no-eval (treesit-parser-included-ranges parser)
   :eg-result ((1 . 4) (5 . 8)))
  (treesit-query-range
   :no-eval (treesit-query-range node '((script_element) @cap))
   :eg-result ((1 . 4) (5 . 8)))


  "Retrieving a node"
  (treesit-node-at
   :no-eval (treesit-node-at (point))
   :eg-result-string "#<treesit-node (identifier) in 179-180>")
  (treesit-node-on
   :no-eval (treesit-node-on 18 28)
   :eg-result-string "#<treesit-node (compound_statement) in 143-290>")
  (treesit-buffer-root-node
   :no-eval (treesit-buffer-root-node)
   :eg-result-string "#<treesit-node (translation_unit) in 1-4830>")
  (treesit-parser-root-node
   :no-eval (treesit-parser-root-node parser)
   :eg-result-string "#<treesit-node (translation_unit) in 1-4830>")


  "Retrieving a node from another node"
  (treesit-node-get
      :no-eval (treesit-node-get node '((parent 1) (sibling 1) (text)))
      :eg-result-string "#<treesit-node (declaration) in 1-11>")
  (treesit-node-parent
   :no-eval (treesit-node-parent node)
   :eg-result-string "#<treesit-node (declaration) in 1-11>")
  (treesit-node-child
   :no-eval (treesit-node-child node 0)
   :eg-result-string "#<treesit-node (primitive_type) in 1-4>")
  (treesit-node-children
   :no-eval (treesit-node-children node)
   :eg-result-string "(#<treesit-node (primitive_type) in 1-4> #<treesit-node (init_declarator) in 5-10> #<treesit-node \";\" in 10-11>)")
  (treesit-node-next-sibling
   :no-eval (treesit-node-next-sibling node)
   :eg-result-string "#<treesit-node (init_declarator) in 5-10>")
  (treesit-node-prev-sibling
   :no-eval (treesit-node-prev-sibling node)
   :eg-result-string "#<treesit-node (primitive_type) in 1-4>")
  (treesit-node-child-by-field-name
   :no-eval (treesit-node-child-by-field-name node "declarator")
   :eg-result-string "#<treesit-node (init_declarator) in 5-10>")


  (treesit-node-first-child-for-pos
   :no-eval (treesit-node-first-child-for-pos node 1)
   :eg-result-string "#<treesit-node (primitive_type) in 1-4>")
  (treesit-node-descendant-for-range
   :no-eval (treesit-node-descendant-for-range node 2 3)
   :eg-result-string "#<treesit-node (primitive_type) in 1-4>")


  "Searching for node"
  (treesit-search-subtree
   :no-eval (treesit-search-subtree node "function_definition")
   :eg-result-string "#<treesit-node (function_definition) in 57-146>")
  (treesit-search-forward
   :no-eval (treesit-search-forward node "function_definition")
   :eg-result-string "#<treesit-node (function_definition) in 57-146>")
  (treesit-search-forward-goto
   :no-eval (treesit-search-forward-goto node "function_definition")
   :eg-result-string "#<treesit-node (function_definition) in 57-146>")
  (treesit-induce-sparse-tree
   :no-eval (treesit-induce-sparse-tree node "function_definition")
   :eg-result-string "(nil (#<treesit-node (function_definition) in 57-146>) (#<treesit-node (function_definition) in 259-296>) (#<treesit-node (function_definition) in 303-659>))")
  (treesit-filter-child
   :no-eval (treesit-filter-child node (lambda (n) (equal (treesit-node-type) "identifier")))
   :eg-result-string "(#<treesit-node (identifier) in 195-196>)")
  (treesit-parent-until
   :no-eval (treesit-parent-until node (lambda (p) (eq (treesit-node-start p) (point))))
   :eg-result-string "#<treesit-node (declaration) in 1-11>")
  (treesit-parent-while
   :no-eval (treesit-parent-while node (lambda (p) (eq (treesit-node-start p) (point))))
   :eg-result-string "#<treesit-node (declaration) in 1-11>")
  (treesit-node-top-level
   :no-eval (treesit-node-top-level node)
   :eg-result-string "#<treesit-node (declaration) in 1-11>")


  "Retrieving node information"
  (treesit-node-text
   :no-eval (treesit-node-text node)
   :eg-result "int")
  (treesit-node-start
   :no-eval (treesit-node-start node)
   :eg-result 1)
  (treesit-node-end
   :no-eval (treesit-node-end node)
   :eg-result 10)
  (treesit-node-type
   :no-eval (treesit-node-type node)
   :eg-result "function_definition")
  (treesit-node-field-name
   :no-eval (treesit-node-field-name node)
   :eg-result "body")


  (treesit-node-parser
   :no-eval (treesit-node-parser node)
   :eg-result-string "#<treesit-parser for c>")
  (treesit-node-language
   :no-eval (treesit-node-language node)
   :eg-result c)
  (treesit-node-buffer
   :no-eval (treesit-node-buffer node)
   :eg-result-string "#<buffer xdisp.c>")


  (treesit-node-index
   :no-eval (treesit-node-index node)
   :eg-result 0)
  (treesit-node-string
   :no-eval (treesit-node-string node)
   :eg-result-string "(init_declarator declarator: (identifier) value: (number_literal))")
  (treesit-node-check
   :no-eval (treesit-node-check node 'named)
   :eg-result t)
  (treesit-node-enclosed-p
   :no-eval (treesit-node-enclosed-p node1 node2)
   :no-eval (treesit-node-enclosed-p node1 '(12 . 18)))

  (treesit-node-field-name-for-child
   :no-eval (treesit-node-field-name-for-child node)
   :eg-result "body")
  (treesit-node-child-count
   :no-eval (treesit-node-child-count node)
   :eg-result 3)


  "Pattern matching"
  (treesit-query-capture
   :no-eval (treesit-query-capture node '((identifier) @id "return" @ret))
   :eg-result-string "((id . #<treesit-node (identifier) in 195-196>) (ret . #<treesit-node "return" in 338-344>))")
  (treesit-query-compile
   :no-eval (treesit-query-compile 'c '((identifier) @id "return" @ret))
   :eg-result-string "#<treesit-compiled-query>")
  (treesit-query-language
   :no-eval (treesit-query-language compiled-query)
   :eg-result c)
  (treesit-query-expand
   :eval (treesit-query-expand '((identifier) @id "return" @ret)))
  (treesit-pattern-expand
   :eval (treesit-pattern-expand :anchor)
   :eval (treesit-pattern-expand '(identifier))
   :eval (treesit-pattern-expand :equal))


  "Parsing a string"
  (treesit-parse-string
   :no-eval (treesit-parse-string "int c = 0;" 'c)
   :eg-result-string "#<treesit-node (translation_unit) in 1-11>")
  (treesit-query-string
   :no-eval (treesit-query-string "int c = 0;" '((identifier) @id) 'c)
   :eg-result-string "((id . #<treesit-node (identifier) in 5-6>))")

  "Misc"
  (treesit-subtree-stat
   :no-eval (treesit-subtree-stat node)
   :eg-result (6 33 487)))

(provide 'treesit)

;;; treesit.el ends here
