;;; templatel.el --- Templating language; -*- lexical-binding: t -*-
;;
;; Author: Lincoln Clarete <lincoln@clarete.li>
;; URL: https://clarete.li/templatel
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.1"))
;;
;; Copyright (C) 2020  Lincoln Clarete
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;; Inspired by Jinja, this teeny language compiles templates into
;; Emacs Lisp functions that can be called with different sets of
;; variables.  Among its main features, it supports if statements, for
;; loops, and a good amount of expressions that make it simpler to
;; manipulate data within the template.
;;
;;; Code:

(require 'seq)
(require 'subr-x)

(define-error 'templatel-syntax-error "Syntax Error" 'templatel-error)

(define-error 'templatel-runtime-error "Runtime Error" 'templatel-error)

(define-error 'templatel-backtracking "Backtracking" 'templatel-internal)

;; --- Scanner ---

(defun templatel--scanner-new (input file-name)
  "Create scanner for INPUT named FILE-NAME."
  (list input 0 0 0 file-name))

(defun templatel--scanner-input (scanner)
  "Input that SCANNER is operating on."
  (car scanner))

(defun templatel--scanner-cursor (scanner)
  "Cursor position of SCANNER."
  (cadr scanner))

(defun templatel--scanner-cursor-set (scanner value)
  "Set SCANNER's cursor to VALUE."
  (setf (cadr scanner) value))

(defun templatel--scanner-cursor-incr (scanner)
  "Increment SCANNER's cursor."
  (templatel--scanner-cursor-set scanner (+ 1 (templatel--scanner-cursor scanner))))

(defun templatel--scanner-file (scanner)
  "Line the SCANNER's cursor is in."
  (elt scanner 4))

(defun templatel--scanner-line (scanner)
  "Line the SCANNER's cursor is in."
  (caddr scanner))

(defun templatel--scanner-line-set (scanner value)
  "Set SCANNER's line to VALUE."
  (setf (caddr scanner) value))

(defun templatel--scanner-line-incr (scanner)
  "Increment SCANNER's line and reset col."
  (templatel--scanner-col-set scanner 0)
  (templatel--scanner-line-set scanner (+ 1 (templatel--scanner-line scanner))))

(defun templatel--scanner-col (scanner)
  "Column the SCANNER's cursor is in."
  (cadddr scanner))

(defun templatel--scanner-col-set (scanner value)
  "Set column of the SCANNER as VALUE."
  (setf (cadddr scanner) value))

(defun templatel--scanner-col-incr (scanner)
  "Increment SCANNER's col."
  (templatel--scanner-col-set scanner (+ 1 (templatel--scanner-col scanner))))

(defun templatel--scanner-state (scanner)
  "Return a copy o SCANNER's state."
  (copy-sequence (cdr scanner)))

(defun templatel--scanner-state-set (scanner state)
  "Set SCANNER's state with STATE."
  (templatel--scanner-cursor-set scanner (car state))
  (templatel--scanner-line-set scanner (cadr state))
  (templatel--scanner-col-set scanner (caddr state)))

(defun templatel--scanner-current (scanner)
  "Peak the nth cursor of SCANNER's input."
  (if (templatel--scanner-eos scanner)
      (templatel--scanner-error scanner "EOF")
    (elt (templatel--scanner-input scanner)
         (templatel--scanner-cursor scanner))))

(defun templatel--scanner-error (_scanner msg)
  "Generate error in SCANNER and document with MSG."
  (signal 'templatel-backtracking msg))

(defun templatel--scanner-eos (scanner)
  "Return t if cursor is at the end of SCANNER's input."
  (eq (templatel--scanner-cursor scanner)
      (length (templatel--scanner-input scanner))))

(defun templatel--scanner-next (scanner)
  "Push SCANNER's cursor one character."
  (if (templatel--scanner-eos scanner)
      (templatel--scanner-error scanner "EOF")
    (progn
      (templatel--scanner-col-incr scanner)
      (templatel--scanner-cursor-incr scanner))))

(defun templatel--scanner-any (scanner)
  "Match any character on SCANNER's input minus EOF."
  (let ((current (templatel--scanner-current scanner)))
    (templatel--scanner-next scanner)
    current))

(defun templatel--scanner-match (scanner c)
  "Match current character under SCANNER's to C."
  (if (eq c (templatel--scanner-current scanner))
      (progn (templatel--scanner-next scanner) c)
    (templatel--scanner-error scanner
                              (format
                               "Expected %s, got %s" c (templatel--scanner-current scanner)))))

(defun templatel--scanner-matchs (scanner s)
  "Match SCANNER's input to string S."
  (mapcar (lambda (i) (templatel--scanner-match scanner i)) s))

(defun templatel--scanner-range (scanner a b)
  "Succeed if SCANNER's current entry is between A and B."
  (let ((c (templatel--scanner-current scanner)))
    (if (and (>= c a) (<= c b))
        (templatel--scanner-any scanner)
      (templatel--scanner-error scanner (format "Expected %s-%s, got %s" a b c)))))

(defun templatel--scanner-or (scanner options)
  "Read the first one of OPTIONS that works SCANNER."
  (if (null options)
      (templatel--scanner-error scanner "No valid options")
    (let ((state (templatel--scanner-state scanner)))
      (condition-case nil
          (funcall (car options))
        (templatel-internal
         (progn (templatel--scanner-state-set scanner state)
                (templatel--scanner-or scanner (cdr options))))))))

(defun templatel--scanner-optional (scanner expr)
  "Read EXPR from SCANNER returning nil if it fails."
  (let ((state (templatel--scanner-state scanner)))
    (condition-case nil
        (funcall expr)
      (templatel-internal
       (templatel--scanner-state-set scanner state)
       nil))))

(defun templatel--scanner-not (scanner expr)
  "Fail if EXPR succeed, succeed when EXPR fail using SCANNER."
  (let ((cursor (templatel--scanner-cursor scanner))
        (succeeded (condition-case nil
                       (funcall expr)
                     (templatel-internal
                      nil))))
    (templatel--scanner-cursor-set scanner cursor)
    (if succeeded
        (templatel--scanner-error scanner "Not meant to succeed")
      t)))

(defun templatel--scanner-zero-or-more (scanner expr)
  "Read EXPR zero or more time from SCANNER."
  (let (output
        (running t))
    (while running
      (let ((state (templatel--scanner-state scanner)))
        (condition-case nil
            (setq output (cons (funcall expr) output))
          (templatel-internal
           (progn
             (templatel--scanner-state-set scanner state)
             (setq running nil))))))
    (reverse output)))

(defun templatel--scanner-one-or-more (scanner expr)
  "Read EXPR one or more time from SCANNER."
  (cons (funcall expr)
        (templatel--scanner-zero-or-more scanner expr)))

(defun templatel--token-expr-op (scanner)
  "Read '{{' off SCANNER's input."
  (templatel--scanner-matchs scanner "{{")
  (templatel--parser-_ scanner))

(defun templatel--token-stm-op (scanner)
  "Read '{%' off SCANNER's input."
  (templatel--scanner-matchs scanner "{%")
  (templatel--parser-_ scanner))

(defun templatel--token-comment-op (scanner)
  "Read '{#' off SCANNER's input."
  (templatel--scanner-matchs scanner "{#")
  (templatel--parser-_ scanner))

;; Notice these two tokens don't consume white spaces right after the
;; closing tag. That gets us a little closer to preserving entirely
;; the input provided to the parser.
(defun templatel--token-expr-cl (scanner)
  "Read '}}' off SCANNER's input."
  (templatel--scanner-matchs scanner "}}"))

(defun templatel--token-stm-cl (scanner)
  "Read '%}' off SCANNER's input."
  (templatel--scanner-matchs scanner "%}"))

(defun templatel--token-comment-cl (scanner)
  "Read '#}' off SCANNER's input."
  (templatel--scanner-matchs scanner "#}"))

(defun templatel--token-dot (scanner)
  "Read '.' off SCANNER's input."
  (templatel--scanner-matchs scanner ".")
  (templatel--parser-_ scanner))

(defun templatel--token-comma (scanner)
  "Read ',' off SCANNER's input."
  (templatel--scanner-matchs scanner ",")
  (templatel--parser-_ scanner))

(defun templatel--token-if (scanner)
  "Read 'if' off SCANNER's input."
  (templatel--scanner-matchs scanner "if")
  (templatel--parser-_ scanner))

(defun templatel--token-elif (scanner)
  "Read 'elif' off SCANNER's input."
  (templatel--scanner-matchs scanner "elif")
  (templatel--parser-_ scanner))

(defun templatel--token-else (scanner)
  "Read 'else' off SCANNER's input."
  (templatel--scanner-matchs scanner "else")
  (templatel--parser-_ scanner))

(defun templatel--token-endif (scanner)
  "Read 'endif' off SCANNER's input."
  (templatel--scanner-matchs scanner "endif")
  (templatel--parser-_ scanner))

(defun templatel--token-for (scanner)
  "Read 'for' off SCANNER's input."
  (templatel--scanner-matchs scanner "for")
  (templatel--parser-_ scanner))

(defun templatel--token-endfor (scanner)
  "Read 'endfor' off SCANNER's input."
  (templatel--scanner-matchs scanner "endfor")
  (templatel--parser-_ scanner))

(defun templatel--token-block (scanner)
  "Read 'block' off SCANNER's input."
  (templatel--scanner-matchs scanner "block")
  (templatel--parser-_ scanner))

(defun templatel--token-endblock (scanner)
  "Read 'endblock' off SCANNER's input."
  (templatel--scanner-matchs scanner "endblock")
  (templatel--parser-_ scanner))

(defun templatel--token-extends (scanner)
  "Read 'extends' off SCANNER's input."
  (templatel--scanner-matchs scanner "extends")
  (templatel--parser-_ scanner))

(defun templatel--token-in (scanner)
  "Read 'in' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "in")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-and (scanner)
  "Read 'and' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "and")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-not (scanner)
  "Read 'not' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "not")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-or (scanner)
  "Read 'or' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "or")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-paren-op (scanner)
  "Read '(' off SCANNER's input."
  (templatel--scanner-matchs scanner "(")
  (templatel--parser-_ scanner))

(defun templatel--token-paren-cl (scanner)
  "Read ')' off SCANNER's input."
  (templatel--scanner-matchs scanner ")")
  (templatel--parser-_ scanner))

(defun templatel--token-| (scanner)
  "Read '|' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "|")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-|| (scanner)
  "Read '||' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "||")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-+ (scanner)
  "Read '+' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "+")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-- (scanner)
  "Read '-' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "-")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-* (scanner)
  "Read '*' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "*")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-** (scanner)
  "Read '**' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "**")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-slash (scanner)
  "Read '/' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "/")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-dslash (scanner)
  "Read '//' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "//")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-== (scanner)
  "Read '==' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "==")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-!= (scanner)
  "Read '!=' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "!=")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-> (scanner)
  "Read '>' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner ">")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-< (scanner)
  "Read '<' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "<")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token->= (scanner)
  "Read '>=' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner ">=")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-<= (scanner)
  "Read '<=' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "<=")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-<< (scanner)
  "Read '<<' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "<<")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token->> (scanner)
  "Read '>>' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner ">>")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-& (scanner)
  "Read '&' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "&")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-~ (scanner)
  "Read '~' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "~")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-% (scanner)
  "Read '%' off SCANNER's input."
  ;; This is needed or allowing a cutting point to be introduced right
  ;; after the operator of a binary expression.
  (templatel--scanner-not scanner (lambda() (templatel--token-stm-cl scanner)))
  (let ((m (templatel--scanner-matchs scanner "%")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--token-^ (scanner)
  "Read '^' off SCANNER's input."
  (let ((m (templatel--scanner-matchs scanner "^")))
    (templatel--parser-_ scanner)
    (templatel--parser-join-chars m)))

(defun templatel--parser-join-chars (chars)
  "Join all the CHARS forming a string."
  (string-join (mapcar #'byte-to-string chars) ""))



;; --- Parser ---

(defun templatel--parser-rstrip-comment (scanner thing)
  "SCANNER THING."
  (let ((value (funcall thing scanner)))
    (templatel--scanner-zero-or-more
     scanner
     (lambda() (templatel--parser-comment scanner)))
    value))

;; Template      <- Comment* (Text Comment* / Statement Comment* / Expression Comment*)+
(defun templatel--parser-template (scanner)
  "Parse Template entry from SCANNER's input."
  (templatel--scanner-zero-or-more
   scanner
   (lambda() (templatel--parser-comment scanner)))
  (cons
   "Template"
   (templatel--scanner-one-or-more
    scanner
    (lambda() (templatel--scanner-or
               scanner
               (list (lambda() (templatel--parser-rstrip-comment scanner #'templatel--parser-text))
                     (lambda() (templatel--parser-rstrip-comment scanner #'templatel--parser-statement))
                     (lambda() (templatel--parser-rstrip-comment scanner #'templatel--parser-expression))))))))

;; Text <- (!(_EXPR_OPEN / _STM_OPEN / _COMMENT_OPEN) .)+
(defun templatel--parser-text (scanner)
  "Parse Text entries from SCANNER's input."
  (cons
   "Text"
   (templatel--parser-join-chars
    (templatel--scanner-one-or-more
     scanner
     (lambda()
       (templatel--scanner-not
        scanner
        (lambda()
          (templatel--scanner-or
           scanner
           (list
            (lambda() (templatel--token-expr-op scanner))
            (lambda() (templatel--token-stm-op scanner))
            (lambda() (templatel--token-comment-op scanner))))))
       (let ((chr (templatel--scanner-any scanner)))
         (if (eq chr ?\n)
             (templatel--scanner-line-incr scanner))
         chr))))))

;; Statement     <- IfStatement / ForStatement / BlockStatement / ExtendsStatement
(defun templatel--parser-statement (scanner)
  "Parse a statement from SCANNER."
  (templatel--scanner-or
   scanner
   (list
    (lambda() (templatel--parser-if-stm scanner))
    (lambda() (templatel--parser-for-stm scanner))
    (lambda() (templatel--parser-block-stm scanner))
    (lambda() (templatel--parser-extends-stm scanner)))))

;; IfStatement   <- _If Expr _STM_CLOSE Template Elif
;;                / _If Expr _STM_CLOSE Template Else
;;                / _If Expr _STM_CLOSE Template _EndIf
(defun templatel--parser-if-stm (scanner)
  "SCANNER."
  (templatel--scanner-or
   scanner
   (list (lambda() (templatel--parser-if-stm-elif scanner))
         (lambda() (templatel--parser-if-stm-else scanner))
         (lambda() (templatel--parser-if-stm-endif scanner)))))

(defun templatel--parser-stm-cl (scanner)
  "Read stm-cl off SCANNER or error out if it's not there."
  (templatel--parser-cut
   scanner
   (lambda() (templatel--token-stm-cl scanner))
   "Statement not closed with \"%}\""))

;; _If Expr _STM_CLOSE Template Elif+ Else?
(defun templatel--parser-if-stm-elif (scanner)
  "Parse elif from SCANNER."
  (templatel--parser-if scanner)
  (let* ((expr (templatel--parser-expr scanner))
         (_ (templatel--parser-stm-cl scanner))
         (tmpl (templatel--parser-template scanner))
         (elif (templatel--scanner-one-or-more scanner (lambda() (templatel--parser-elif scanner))))
         (else (templatel--scanner-optional scanner (lambda() (templatel--parser-else scanner)))))
    (cons "IfElif" (list expr tmpl elif else))))

;; _If Expr _STM_CLOSE Template Else
(defun templatel--parser-if-stm-else (scanner)
  "Parse else from SCANNER."
  (templatel--parser-if scanner)
  (let* ((expr (templatel--parser-expr scanner))
         (_ (templatel--parser-stm-cl scanner))
         (tmpl (templatel--parser-template scanner))
         (else (templatel--parser-else scanner)))
    (cons "IfElse" (list expr tmpl else))))

;; _If Expr _STM_CLOSE Template _EndIf
(defun templatel--parser-if-stm-endif (scanner)
  "Parse endif from SCANNER."
  (templatel--parser-if scanner)
  (let* ((expr (templatel--parser-expr scanner))
         (_    (templatel--parser-stm-cl scanner))
         (tmpl (templatel--parser-template scanner))
         (_    (templatel--parser-endif scanner)))
    (cons "IfStatement" (list expr tmpl))))

;; Elif          <- _STM_OPEN _elif Expr _STM_CLOSE Template
(defun templatel--parser-elif (scanner)
  "Parse elif expression off SCANNER."
  (templatel--token-stm-op scanner)
  (templatel--token-elif scanner)
  (let ((expr (templatel--parser-expr scanner))
        (_    (templatel--parser-stm-cl scanner))
        (tmpl (templatel--parser-template scanner)))
    (cons "Elif" (list expr tmpl))))

;; _If           <- _STM_OPEN _if
(defun templatel--parser-if (scanner)
  "Parse if condition off SCANNER."
  (templatel--token-stm-op scanner)
  (templatel--token-if scanner))

;; Else          <- _STM_OPEN _else _STM_CLOSE Template _EndIf
(defun templatel--parser-else (scanner)
  "Parse else expression off SCANNER."
  (templatel--token-stm-op scanner)
  (templatel--token-else scanner)
  (templatel--parser-stm-cl scanner)
  (let ((tmpl (templatel--parser-template scanner)))
    (templatel--parser-endif scanner)
    (cons "Else" (list tmpl))))

;; _EndIf        <- _STM_OPEN _endif _STM_CLOSE
(defun templatel--parser-endif (scanner)
  "Parse endif tag off SCANNER."
  (templatel--parser-cut
   scanner
   (lambda()
     (templatel--token-stm-op scanner)
     (templatel--token-endif scanner)
     (templatel--parser-stm-cl scanner))
   "Missing endif statement"))

;; ForStatement  <- _For Expr _in Expr _STM_CLOSE Template _EndFor
;; _For          <- _STM_OPEN _for
(defun templatel--parser-for-stm (scanner)
  "Parse for statement from SCANNER."
  (templatel--token-stm-op scanner)
  (templatel--token-for scanner)
  (let ((iter (templatel--parser-identifier scanner))
        (_ (templatel--token-in scanner))
        (iterable (templatel--parser-expr scanner))
        (_ (templatel--parser-stm-cl scanner))
        (tmpl (templatel--parser-template scanner))
        (_ (templatel--parser-endfor scanner)))
    (cons "ForStatement" (list iter iterable tmpl))))

;; _EndFor       <- _STM_OPEN _endfor _STM_CLOSE
(defun templatel--parser-endfor (scanner)
  "Parse {% endfor %} statement from SCANNER."
  (templatel--parser-cut
   scanner
   (lambda()
     (templatel--token-stm-op scanner)
     (templatel--token-endfor scanner)
     (templatel--parser-stm-cl scanner))
   "Missing endfor statement"))

;; BlockStatement <- _Block String _STM_CLOSE Template? _EndBlock
(defun templatel--parser-block-stm (scanner)
  "Parse block statement from SCANNER."
  (templatel--token-stm-op scanner)
  (templatel--token-block scanner)
  (let ((name (templatel--parser-cut
               scanner
               (lambda() (templatel--parser-identifier scanner))
               "Missing block name"))
        (_ (templatel--parser-_ scanner))
        (_ (templatel--parser-stm-cl scanner))
        (tmpl (templatel--scanner-optional
               scanner
               (lambda() (templatel--parser-template scanner)))))
    (templatel--parser-endblock scanner)
    (cons "BlockStatement" (list name tmpl))))

;; _EndBlock       <- _STM_OPEN _endblock _STM_CLOSE
(defun templatel--parser-endblock (scanner)
  "Parse {% endblock %} statement from SCANNER."
  (templatel--parser-cut
   scanner
   (lambda()
     (templatel--token-stm-op scanner)
     (templatel--token-endblock scanner)
     (templatel--parser-stm-cl scanner))
   "Missing endblock statement"))

;; ExtendsStatement <- _STM_OPEN _extends String _STM_CLOSE
(defun templatel--parser-extends-stm (scanner)
  "Parse extends statement from SCANNER."
  (templatel--token-stm-op scanner)
  (templatel--token-extends scanner)
  (let ((name (templatel--parser-cut
               scanner
               (lambda() (templatel--parser-string scanner))
               "Missing template name in extends statement")))
    (templatel--parser-_ scanner)
    (templatel--parser-stm-cl scanner)
    (cons "ExtendsStatement" (list name))))

;; Expression    <- _EXPR_OPEN Expr _EXPR_CLOSE
(defun templatel--parser-expression (scanner)
  "SCANNER."
  (templatel--token-expr-op scanner)
  (let ((expr (templatel--parser-expr scanner)))
    (templatel--parser-cut
     scanner
     (lambda() (templatel--token-expr-cl scanner))
     "Unclosed bracket")
    (cons "Expression" (list expr))))

;; Expr          <- Filter
(defun templatel--parser-expr (scanner)
  "Read an expression from SCANNER."
  (cons
   "Expr"
   (list (templatel--parser-filter scanner))))

(defun templatel--parser-cut (scanner fn msg)
  "Try to parse FN off SCANNER or error with MSG.

There are two types of errors emitted by this parser:
 1. Backtracking (internal), which is caught by most scanner
    functions, like templatel--scanner-or and templatel--scanner-zero-or-more.
 2. Syntax Error (public), which signals an unrecoverable parsing
    error.

This function catches backtracking errors and transform them in
syntax errors.  It must be carefully explicitly on places where
backtracking should be interrupted earlier."
  (condition-case nil
      (funcall fn)
    (templatel-internal
     (signal 'templatel-syntax-error
             (format "%s at %s,%s: %s"
                     (or (templatel--scanner-file scanner) "<string>")
                     (1+ (templatel--scanner-line scanner))
                     (1+ (templatel--scanner-col scanner))
                     msg)))))

(defun templatel--parser-item-or-named-collection (name first rest)
  "NAME FIRST REST."
  (if (null rest)
      first
    (cons name (cons first rest))))

(defun templatel--parser-binary (scanner name randfn ratorfn)
  "Parse binary operator NAME from SCANNER.

A binary operator needs two functions: one for reading the
operands (RANDFN) and another one to read the
operator (RATORFN)."
  (templatel--parser-item-or-named-collection
   (if (null name) "BinOp" name)
   (funcall randfn scanner)
   (templatel--scanner-zero-or-more
    scanner
    (lambda()
      (cons
       (funcall ratorfn scanner)
       (templatel--parser-cut
        scanner
        (lambda() (funcall randfn scanner))
        "Missing operand after binary operator"))))))

;; Filter        <- Logical (_PIPE Logical)*
(defun templatel--parser-filter (scanner)
  "Read Filter from SCANNER."
  (templatel--parser-binary scanner "Filter" #'templatel--parser-logical #'templatel--token-|))

;; Logical       <- BitLogical ((AND / OR) BitLogical)*
(defun templatel--parser-logical (scanner)
  "Read Logical from SCANNER."
  (templatel--parser-binary
   scanner
   nil ; "Logical"
   #'templatel--parser-bit-logical
   (lambda(s)
     (templatel--scanner-or
      s
      (list
       (lambda() (templatel--token-and s))
       (lambda() (templatel--token-or s)))))))

;; BitLogical    <- Comparison ((BAND / BXOR / BOR) Comparison)*
(defun templatel--parser-bit-logical (scanner)
  "Read BitLogical from SCANNER."
  (templatel--parser-binary
   scanner
   nil ; "BitLogical"
   #'templatel--parser-comparison
   (lambda(s)
     (templatel--scanner-or
      s
      (list
       (lambda() (templatel--token-& s))
       (lambda() (templatel--token-^ s))
       (lambda() (templatel--token-|| s)))))))

;; Comparison    <- BitShifting ((EQ / NEQ / LTE / GTE / LT / GT / IN) BitShifting)*
(defun templatel--parser-comparison (scanner)
  "Read a Comparison from SCANNER."
  (templatel--parser-binary
   scanner
   nil ; "Comparison"
   #'templatel--parser-bit-shifting
   (lambda(s)
     (templatel--scanner-or
      s
      (list
       (lambda() (templatel--token-== s))
       (lambda() (templatel--token-!= s))
       (lambda() (templatel--token-<= s))
       (lambda() (templatel--token->= s))
       (lambda() (templatel--token-< s))
       (lambda() (templatel--token-> s))
       (lambda() (templatel--token-in s)))))))

;; BitShifting   <- Term ((RSHIFT / LSHIFT) Term)*
(defun templatel--parser-bit-shifting (scanner)
  "Read a BitShifting from SCANNER."
  (templatel--parser-binary
   scanner
   nil ; "BitShifting"
   #'templatel--parser-term
   (lambda(s)
     (templatel--scanner-or
      s
      (list
       (lambda() (templatel--token->> s))
       (lambda() (templatel--token-<< s)))))))

;; Term          <- Factor ((PLUS / MINUS) Factor)*
(defun templatel--parser-term (scanner)
  "Read Term from SCANNER."
  (templatel--parser-binary
   scanner
   nil ; "Term"
   #'templatel--parser-factor
   (lambda(s)
     (templatel--scanner-or
      s
      (list
       (lambda() (templatel--token-+ s))
       (lambda() (templatel--token-- s)))))))

;; Factor        <- Power ((STAR / DSLASH / SLASH) Power)*
(defun templatel--parser-factor (scanner)
  "Read Factor from SCANNER."
  (templatel--parser-binary
   scanner
   nil ; "Factor"
   #'templatel--parser-power
   (lambda(s)
     (templatel--scanner-or
      s
      (list
       (lambda() (templatel--token-* s))
       (lambda() (templatel--token-slash s))
       (lambda() (templatel--token-dslash s)))))))

;; Power         <- Unary ((POWER / MOD) Unary)*
(defun templatel--parser-power (scanner)
  "Read Power from SCANNER."
  (templatel--parser-binary
   scanner
   nil ; "Power"
   #'templatel--parser-unary
   (lambda(s)
     (templatel--scanner-or
      s
      (list
       (lambda() (templatel--token-** s))
       (lambda() (templatel--token-% s)))))))

;; UnaryOp       <- PLUS / MINUS / NOT / BNOT
(defun templatel--parser-unary-op (scanner)
  "Read an Unary operator from SCANNER."
  (templatel--scanner-or
   scanner
   (list
    (lambda() (templatel--token-+ scanner))
    (lambda() (templatel--token-- scanner))
    (lambda() (templatel--token-~ scanner))
    (lambda() (templatel--token-not scanner)))))

;; Unary         <- UnaryOp Unary / UnaryOp Primary / Primary
(defun templatel--parser-unary (scanner)
  "Read Unary from SCANNER."
  (templatel--scanner-or
   scanner
   (list
    (lambda()
      (cons
       "Unary"
       (list
        (templatel--parser-unary-op scanner)
        (templatel--parser-unary scanner))))
    (lambda()
      (cons
       "Unary"
       (list
        (templatel--parser-unary-op scanner)
        (templatel--parser-cut
         scanner
         (lambda() (templatel--parser-primary scanner))
         "Missing operand after unary operator"))))
    (lambda() (templatel--parser-primary scanner)))))

;; Primary       <- _PAREN_OPEN Expr _PAREN_CLOSE
;;                / Element
(defun templatel--parser-primary (scanner)
  "Read Primary from SCANNER."
  (templatel--scanner-or
   scanner
   (list
    (lambda()
      (templatel--token-paren-op scanner)
      (let ((expr (templatel--parser-expr scanner)))
        (templatel--token-paren-cl scanner)
        expr))
    (lambda() (templatel--parser-element scanner)))))

;; Attribute     <- Identifier (_dot Identifier)+
(defun templatel--parser-attribute (scanner)
  "Read an Attribute from SCANNER."
  (cons
   "Attribute"
   (cons
    (templatel--parser-identifier scanner)
    (progn
      (templatel--token-dot scanner)
      (templatel--scanner-one-or-more
       scanner
       (lambda() (templatel--parser-identifier scanner)))))))

;; Element       <- Value / Attribute / FnCall / Identifier
(defun templatel--parser-element (scanner)
  "Read Element off SCANNER."
  (cons
   "Element"
   (list
    (templatel--scanner-or
     scanner
     (list
      (lambda() (templatel--parser-value scanner))
      (lambda() (templatel--parser-attribute scanner))
      (lambda() (templatel--parser-fncall scanner))
      (lambda() (templatel--parser-identifier scanner)))))))

;; FnCall        <- Identifier ParamList
(defun templatel--parser-fncall (scanner)
  "Read FnCall off SCANNER."
  (cons
   "FnCall"
   (cons
    (templatel--parser-identifier scanner)
    (templatel--parser-paramlist scanner))))

;; -paramlist   <- _PAREN_OPEN Expr (_COMMA Expr)* _PAREN_CLOSE
(defun templatel--parser--paramlist (scanner)
  "Read parameter list from SCANNER."
  (templatel--token-paren-op scanner)
  (let ((first (templatel--parser-expr scanner))
        (rest (templatel--scanner-zero-or-more
               scanner
               (lambda()
                 (templatel--token-comma scanner)
                 (templatel--parser-expr scanner)))))
    (templatel--token-paren-cl scanner)
    (cons first rest)))

;; ParamList     <- -paramlist
;;                / _PAREN_OPEN _PAREN_CLOSE
(defun templatel--parser-paramlist (scanner)
  "Read parameter list off SCANNER."
  (templatel--scanner-or
   scanner
   (list
    (lambda() (templatel--parser--paramlist scanner))
    (lambda()
      (templatel--token-paren-op scanner)
      (templatel--token-paren-cl scanner)
      nil))))

;; Value         <- Number / BOOL / NIL / String
(defun templatel--parser-value (scanner)
  "Read Value from SCANNER."
  (let ((value (templatel--scanner-or
                scanner
                (list
                 (lambda() (templatel--parser-number scanner))
                 (lambda() (templatel--parser-bool scanner))
                 (lambda() (templatel--parser-nil scanner))
                 (lambda() (templatel--parser-string scanner))))))
    (templatel--parser-_ scanner)
    value))

;; Number        <- BIN / HEX / FLOAT / INT
(defun templatel--parser-number (scanner)
  "Read Number off SCANNER."
  (cons
   "Number"
   (templatel--scanner-or
    scanner
    (list
     (lambda() (templatel--parser-bin scanner))
     (lambda() (templatel--parser-hex scanner))
     (lambda() (templatel--parser-float scanner))
     (lambda() (templatel--parser-int scanner))))))

;; INT           <- [0-9]+                  _
(defun templatel--parser-int (scanner)
  "Read integer off SCANNER."
  (string-to-number
   (templatel--parser-join-chars
    (templatel--scanner-one-or-more
     scanner
     (lambda() (templatel--scanner-range scanner ?0 ?9))))
   10))

;; FLOAT         <- [0-9]* '.' [0-9]+       _
(defun templatel--parser-float (scanner)
  "Read float from SCANNER."
  (append
   (templatel--scanner-zero-or-more scanner (lambda() (templatel--scanner-range scanner ?0 ?9)))
   (templatel--scanner-matchs scanner ".")
   (templatel--scanner-one-or-more scanner (lambda() (templatel--scanner-range scanner ?0 ?9)))))

;; BIN           <- '0b' [0-1]+             _
(defun templatel--parser-bin (scanner)
  "Read binary number from SCANNER."
  (templatel--scanner-matchs scanner "0b")
  (string-to-number
   (templatel--parser-join-chars
    (append
     (templatel--scanner-one-or-more
      scanner
      (lambda() (templatel--scanner-range scanner ?0 ?1)))))
   2))

;; HEX           <- '0x' [0-9a-fA-F]+       _
(defun templatel--parser-hex (scanner)
  "Read hex number from SCANNER."
  (templatel--scanner-matchs scanner "0x")
  (string-to-number
   (templatel--parser-join-chars
    (append
     (templatel--scanner-one-or-more
      scanner
      (lambda()
        (templatel--scanner-or
         scanner
         (list (lambda() (templatel--scanner-range scanner ?0 ?9))
               (lambda() (templatel--scanner-range scanner ?a ?f))
               (lambda() (templatel--scanner-range scanner ?A ?F))))))))
   16))

;; BOOL          <- ('true' / 'false')         _
(defun templatel--parser-bool (scanner)
  "Read boolean value from SCANNER."
  (cons
   "Bool"
   (templatel--scanner-or
    scanner
    (list (lambda() (templatel--scanner-matchs scanner "true") t)
          (lambda() (templatel--scanner-matchs scanner "false") nil)))))

;; NIL           <- 'nil'                      _
(defun templatel--parser-nil (scanner)
  "Read nil constant from SCANNER."
  (templatel--scanner-matchs scanner "nil")
  (cons "Nil" nil))

;; String        <- _QUOTE (!_QUOTE .)* _QUOTE _
(defun templatel--parser-string (scanner)
  "Read a double quoted string from SCANNER."
  (templatel--scanner-match scanner ?\")
  (let ((str (templatel--scanner-zero-or-more
              scanner
              (lambda()
                (templatel--scanner-not
                 scanner
                 (lambda() (templatel--scanner-match scanner ?\")))
                (templatel--scanner-any scanner)))))
    (templatel--scanner-match scanner ?\")
    (cons "String" (templatel--parser-join-chars str))))

;; IdentStart    <- [a-zA-Z_]
(defun templatel--parser-identstart (scanner)
  "Read the first character of an identifier from SCANNER."
  (templatel--scanner-or
   scanner
   (list (lambda() (templatel--scanner-range scanner ?a ?z))
         (lambda() (templatel--scanner-range scanner ?A ?Z))
         (lambda() (templatel--scanner-match scanner ?_)))))

;; IdentCont    <- [a-zA-Z0-9_]*  _
(defun templatel--parser-identcont (scanner)
  "Read the rest of an identifier from SCANNER."
  (templatel--scanner-zero-or-more
   scanner
   (lambda()
     (templatel--scanner-or
      scanner
      (list (lambda() (templatel--scanner-range scanner ?a ?z))
            (lambda() (templatel--scanner-range scanner ?A ?Z))
            (lambda() (templatel--scanner-range scanner ?0 ?9))
            (lambda() (templatel--scanner-match scanner ?_)))))))

;; Identifier   <- IdentStart IdentCont
(defun templatel--parser-identifier (scanner)
  "Read Identifier entry from SCANNER."
  (cons
   "Identifier"
   (let ((identifier (templatel--parser-join-chars
                      (cons (templatel--parser-identstart scanner)
                            (templatel--parser-identcont scanner)))))
     (templatel--parser-_ scanner)
     identifier)))

;; _               <- (Space / Comment)*
(defun templatel--parser-_ (scanner)
  "Read whitespaces from SCANNER."
  (templatel--scanner-zero-or-more
   scanner
   (lambda()
     (templatel--scanner-or
      scanner
      (list
       (lambda() (templatel--parser-space scanner))
       (lambda() (templatel--parser-comment scanner)))))))

;; Space           <- ' ' / '\t' / _EOL
(defun templatel--parser-space (scanner)
  "Consume spaces off SCANNER."
  (templatel--scanner-or
   scanner
   (list
    (lambda() (templatel--scanner-matchs scanner " "))
    (lambda() (templatel--scanner-matchs scanner "\t"))
    (lambda() (templatel--parser-eol scanner)))))

;; _EOL            <- '\r\n' / '\n' / '\r'
(defun templatel--parser-eol (scanner)
  "Read end of line from SCANNER."
  (let ((eol (templatel--scanner-or
              scanner
              (list
               (lambda() (templatel--scanner-matchs scanner "\r\n"))
               (lambda() (templatel--scanner-matchs scanner "\n"))
               (lambda() (templatel--scanner-matchs scanner "\r"))))))
    (templatel--scanner-line-incr scanner)
    eol))

;; Comment         <- "{#" (!"#}" .)* "#}"
(defun templatel--parser-comment (scanner)
  "Read comment from SCANNER."
  (templatel--token-comment-op scanner)
  (let ((str (templatel--scanner-zero-or-more
              scanner
              (lambda()
                (templatel--scanner-not
                 scanner
                 (lambda() (templatel--token-comment-cl scanner)))
                (templatel--scanner-any scanner)))))
    (templatel--token-comment-cl scanner)
    (cons "Comment" (templatel--parser-join-chars str))))



;; --- Compiler ---

(defun templatel--compiler-wrap (tree)
  "Compile root node into a function with TREE as body."
  `(lambda(vars &optional env blocks)
     (let* ((rt/blocks (make-hash-table :test 'equal))
            (rt/parent-template nil)
            (rt/varstk (list vars))
            (rt/valstk (list))
            (rt/filters '(("upper" . templatel-filters-upper)
                          ("lower" . templatel-filters-lower)
                          ("sum" . templatel-filters-sum)
                          ("plus1" . templatel-filters-plus1)
                          ("int" . templatel-filters-int)))
            (rt/lookup-var
             (lambda(name)
               (catch '-brk
                 (dolist (ivars (reverse rt/varstk))
                   (let ((value (assoc name ivars)))
                     (unless (null value)
                       (throw '-brk (cdr value)))))
                 (signal
                  'templatel-runtime-error
                  (format "Variable `%s' not declared" name)))))
            ;; The rendering of the template
            (rt/data
             (with-temp-buffer
               ,@tree
               (buffer-string))))
       (if (null rt/parent-template)
           rt/data
         (funcall (templatel-env-source env rt/parent-template) vars env rt/blocks)))))

(defun templatel--compiler-element (tree)
  "Compile an element from TREE."
  `(let ((value ,@(templatel--compiler-run tree)))
     (push value rt/valstk)
     value))

(defun templatel--compiler-expr (tree)
  "Compile an expr from TREE."
  `(progn
     ,@(mapcar #'templatel--compiler-run tree)))

(defun templatel--compiler--attr (tree)
  "Walk through attributes on TREE."
  (if (null (cdr tree))
      (templatel--compiler-identifier (cdar tree))
    `(cdr (assoc ,(cdar tree) ,(templatel--compiler--attr (cdr tree))))))

(defun templatel--compiler-attribute (tree)
  "Compile attribute access from TREE."
  (templatel--compiler--attr (reverse tree)))

(defun templatel--compiler-filter-identifier (item)
  "Compile a filter without params from ITEM.

This filter takes a single parameter: the value being piped into
it.  The code generated must first ensure that such filter is
registered in the local `filters' variable, failing if it isn't.
If the filter exists, it must then call its associated handler."
  (let ((fname (cdar (cdr item))))
    `(let ((entry (assoc ,fname rt/filters)))
       (if (null entry)
           (signal
            'templatel-runtime-error
            (format "Filter `%s' doesn't exist" ,fname))
         (push (funcall (cdr entry) (pop rt/valstk)) rt/valstk)))))

(defun templatel--compiler-filter-fncall (item)
  "Compiler filter with params from ITEM.

A filter can have multiple parameters.  In that case, the value
piped into the filter becomes the first parameter and the other
parameters are shifted to accommodate this change.  E.g.:

  {{ number | int(16) }}

Will be converted into the following:

  (int number 16)

Notice the parameter list is compiled before being passed to the
function call."
  (let ((fname (cdr (cadr (cadr item))))
        (params (cddr (cadr item))))
    `(let ((entry (assoc ,fname rt/filters)))
       (if (null entry)
           (signal
            'templatel-syntax-error
            (format "Filter `%s' doesn't exist" ,fname))
         (push (apply
                (cdr entry)
                (cons (pop rt/valstk)
                      (list ,@(templatel--compiler-run params))))
               rt/valstk)))))

(defun templatel--compiler-filter-item (item)
  "Handle compilation of single filter described by ITEM.

This function routes the item to be compiled to the appropriate
function.  A filter could be either just an identifier or a
function call."
  (if (string= (caar (cddr item)) "Identifier")
      (templatel--compiler-filter-identifier (cdr item))
    (templatel--compiler-filter-fncall (cdr item))))

(defun templatel--compiler-filter-list (tree)
  "Compile filters from TREE.

TREE contains a list of filters that can be either Identifiers or
FnCalls.  This functions job is to iterate over the this list and
call `templatel--compiler-filter-item' on each entry."
  `(progn
     ,(templatel--compiler-run (car tree))
     ,@(mapcar #'templatel--compiler-filter-item (cdr tree))))

(defun templatel--compiler-expression (tree)
  "Compile an expression from TREE."
  `(progn
     ,@(templatel--compiler-run tree)
     (insert (format "%s" (pop rt/valstk)))))

(defun templatel--compiler-text (tree)
  "Compile text from TREE."
  `(insert ,tree))

(defun templatel--compiler-identifier (tree)
  "Compile identifier from TREE."
  `(funcall rt/lookup-var ,tree))

(defun templatel--compiler-if-elif-cond (tree)
  "Compile cond from elif statements in TREE."
  (let ((expr (cadr tree))
        (tmpl (caddr tree)))
    `((progn ,(templatel--compiler-run expr) (pop rt/valstk))
      ,@(templatel--compiler-run tmpl))))

(defun templatel--compiler-if-elif (tree)
  "Compile if/elif/else statement off TREE."
  (let ((expr (car tree))
        (body (cadr tree))
        (elif (caddr tree))
        (else (cadr (cadddr tree))))
    `(cond ((progn ,(templatel--compiler-run expr) (pop rt/valstk))
            ,@(templatel--compiler-run body))
           ,@(mapcar #'templatel--compiler-if-elif-cond elif)
           (t ,@(templatel--compiler-run else)))))

(defun templatel--compiler-if-else (tree)
  "Compile if/else statement off TREE."
  (let ((expr (car tree))
        (body (cadr tree))
        (else (cadr (caddr tree))))
    `(if (progn ,(templatel--compiler-run expr) (pop rt/valstk))
         (progn ,@(templatel--compiler-run body))
       ,@(templatel--compiler-run else))))

(defun templatel--compiler-if (tree)
  "Compile if statement off TREE."
  (let ((expr (car tree))
        (body (cadr tree)))
    `(if (progn ,(templatel--compiler-run expr) (pop rt/valstk))
         (progn ,@(templatel--compiler-run body)))))

(defun templatel--compiler-for (tree)
  "Compile for statement off TREE."
  (let ((id (cdar tree)))
    `(let ((subenv '((,id . nil)))
           (iterable ,(templatel--compiler-run (cadr tree))))
       (push subenv rt/varstk)
       (mapc
        (lambda(id)
          (setf (alist-get ,id subenv) id)
          ,@(templatel--compiler-run (caddr tree)))
        iterable)
       (pop rt/varstk))))

(defun templatel--compiler-binop-item (tree)
  "Compile item from list of binary operator/operand in TREE."
  (if (not (null tree))
      (let* ((tag (caar tree))
             (val (templatel--compiler-run (cdr (car tree))))
             (op (cadr (assoc tag '(;; Arithmetic
                                    ("*" *)
                                    ("/" /)
                                    ("+" +)
                                    ("-" -)
                                    ;; Logic
                                    ("and" and)
                                    ("or" or)
                                    ;; Bit Logic
                                    ("&" logand)
                                    ("||" logior)
                                    ("^" logxor)
                                    ;; Comparison
                                    ("<" <)
                                    (">" >)
                                    ("!=" (lambda(a b) (not (equal a b))))
                                    ("==" equal)
                                    (">=" >=)
                                    ("<=" <=)
                                    ("in" (lambda(a b) (not (null (member a b))))))))))
        (if (not (null val))
            `(progn
               ,val
               ,(templatel--compiler-binop-item (cdr tree))
               (let ((b (pop rt/valstk))
                     (a (pop rt/valstk)))
                 (push (,op a b) rt/valstk)))))))

(defun templatel--compiler-binop (tree)
  "Compile a binary operator from the TREE."
  `(progn
     ,(templatel--compiler-run (car tree))
     ,(templatel--compiler-binop-item (cdr tree))))

(defun templatel--compiler-unary (tree)
  "Compile a unary operator from the TREE."
  (let* ((tag (car tree))
         (val (cadr tree))
         (op (cadr (assoc tag '(("+" (lambda(x) (if (< x 0) (- x) x)))
                                ("-" -)
                                ("~" lognot)
                                ("not" not))))))
    `(progn
       ,(templatel--compiler-run val)
       (push (,op (pop rt/valstk)) rt/valstk))))

(defun templatel--compiler-block (tree)
  "Compile a block statement from TREE."
  (let ((name (cdar tree))
        (body (templatel--compiler-run (cadr tree))))
    `(if (null rt/parent-template)
         (let* ((super-code ',(templatel--compiler-wrap body))
                (subenv (cons "super" (funcall super-code vars env)))
                (code (and blocks (gethash ,name blocks))))
           (if (not (null code))
               (progn
                 (push subenv vars)
                 (insert (funcall code vars env rt/blocks))
                 (pop vars))
             ,@body))
       (puthash ,name ',(templatel--compiler-wrap body) rt/blocks))))

(defun templatel--compiler-extends (tree)
  "Compile an extends statement from TREE."
  `(progn
     (setq rt/parent-template ,(cdar tree))
     (if env
         (templatel-env-run-importfn env rt/parent-template))))

(defun templatel--compiler-run (tree)
  "Compile TREE into bytecode."
  (pcase tree
    (`() nil)
    (`("Template"       . ,a) (templatel--compiler-run a))
    (`("Text"           . ,a) (templatel--compiler-text a))
    (`("Identifier"     . ,a) (templatel--compiler-identifier a))
    (`("Attribute"      . ,a) (templatel--compiler-attribute a))
    (`("Filter"         . ,a) (templatel--compiler-filter-list a))
    (`("Expr"           . ,a) (templatel--compiler-expr a))
    (`("Expression"     . ,a) (templatel--compiler-expression a))
    (`("Element"        . ,a) (templatel--compiler-element a))
    (`("IfElse"         . ,a) (templatel--compiler-if-else a))
    (`("IfElif"         . ,a) (templatel--compiler-if-elif a))
    (`("IfStatement"    . ,a) (templatel--compiler-if a))
    (`("ForStatement"   . ,a) (templatel--compiler-for a))
    (`("BlockStatement" . ,a) (templatel--compiler-block a))
    (`("ExtendsStatement" . ,a) (templatel--compiler-extends a))
    (`("BinOp"          . ,a) (templatel--compiler-binop a))
    (`("Unary"          . ,a) (templatel--compiler-unary a))
    (`("Number"         . ,a) a)
    (`("String"         . ,a) a)
    (`("Bool"           . ,a) a)
    (`("Nil"            . ,a) a)
    ((pred listp)             (mapcar #'templatel--compiler-run tree))
    (_ (message "NOENTIENDO: `%s`" tree))))



(defun templatel-filters-upper (s)
  "Upper case all chars of S."
  (upcase s))

(defun templatel-filters-lower (s)
  "Lower case all chars of S."
  (downcase s))

(defun templatel-filters-sum (s)
  "Sum all entries in S."
  (apply #'+ s))

(defun templatel-filters-plus1 (s)
  "Add one to S."
  (1+ s))

(defun templatel-filters-int (s base)
  "Convert S into integer of base BASE."
  (string-to-number
   (replace-regexp-in-string "^0[xXbB]" "" s) base))

(defun templatel--get (lst sym default)
  "Pick SYM from LST or return DEFAULT."
  (let ((val (assoc sym lst)))
    (if val
        (cadr val)
      default)))

;; --- Public Environment API ---

(defun templatel-env-new (&rest options)
  "Multiple template manager setup with OPTIONS."
  (let* ((opt (seq-partition options 2)))
    ;; where we keep the templates
    `[,(make-hash-table :test 'equal)
      ;; Function used by extends
      ,(templatel--get opt :importfn
                       (lambda(_e _n) (error "Import function not defined")))]))

(defun templatel-env-add-template (env name template)
  "Add TEMPLATE to ENV under key NAME."
  (puthash name template (elt env 0)))

(defun templatel-env-source (env name)
  "Get source code of template NAME within ENV."
  (let ((entry (gethash name (elt env 0))))
    (cdr (assoc 'source entry))))

(defun templatel-env-run-importfn (env name)
  "Run import with NAME within ENV."
  (let ((importfn (elt env 1)))
    (if importfn
        (funcall importfn env name))))

(defun templatel-env-render (env name vars)
  "Render template NAME within ENV with VARS as parameters."
  (funcall (eval (templatel-env-source env name)) vars env))

(defun templatel-new (source)
  "Create a template off SOURCE."
  `((source . ,(templatel--compiler-wrap
                (templatel--compiler-run
                 (templatel--parser-template
                  (templatel--scanner-new source "<string>")))))))

(defun templatel-new-from-file (path)
  "Create a template from file at PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (let* ((scanner (templatel--scanner-new (buffer-string) path))
           (tree (templatel--parser-template scanner))
           (code (templatel--compiler-wrap (templatel--compiler-run tree))))
      `((source . ,code)))))

;; ------ Public API without Environment

(defun templatel-render-string (template variables)
  "Render TEMPLATE string with VARIABLES.

This is the simplest way to use *templatel*, since it only takes
a function call.  However, notice that it won't allow you to
extend other templates because no ~:importfn~ can be passed to
the implicit envoronment created within this function.  Please
refer to the next section
*[[anchor:section-template-environments][Template Environments]]*
to learn how to use the API that enables template inheritance.

#+BEGIN_SRC emacs-lisp
\(templatel-render-string \"Hello, {{ name }}!\" '((\"name\" . \"GNU!\")))
#+END_SRC"
  (let ((env (templatel-env-new)))
    (templatel-env-add-template env "<string>" (templatel-new template))
    (templatel-env-render env "<string>" variables)))

(defun templatel-render-file (path variables)
  "Render template file at PATH with VARIABLES.

Just like with
[[anchor:symbol-templatel-render-string][templatel-render-string]],
templates rendered with this function also can't use ~{% extends
%}~ statements.  Please refer to the section
*[[anchor:section-template-environments][Template Environments]]*
to learn how to use the API that enables template inheritance."
  (let ((env (templatel-env-new)))
    (templatel-env-add-template env path (templatel-new-from-file path))
    (templatel-env-render env path variables)))

(provide 'templatel)
;;; templatel.el ends here
