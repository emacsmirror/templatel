;;; templatel --- Templating language for Emacs-Lisp; -*- lexical-binding: t -*-
;;; Commentary:
;;; Code:

(require 'subr-x)

(define-error 'templatel-syntax-error "Syntax Error" 'templatel-error)

;; --- Scanner ---

(defun scanner/new (input)
  "Create scanner for INPUT."
  (list input 0))

(defun scanner/input (scanner)
  "Input that SCANNER is operating on."
  (car scanner))

(defun scanner/cursor (scanner)
  "Cursor position of SCANNER."
  (cadr scanner))

(defun scanner/cursor/set (scanner value)
  "Set SCANNER's cursor to VALUE."
  (setf (cadr scanner) value))

(defun scanner/cursor/incr (scanner)
  "Increment SCANNER's cursor."
  (scanner/cursor/set scanner (+ 1 (scanner/cursor scanner))))

(defun scanner/current (scanner)
  "Peak the nth cursor of SCANNER's input."
  (if (scanner/eos scanner)
      (scanner/error scanner "EOF")
    (elt (scanner/input scanner)
         (scanner/cursor scanner))))

(defun scanner/error (_scanner msg)
  "Generate error in SCANNER and document with MSG."
  (signal 'templatel-syntax-error msg))

(defun scanner/eos (scanner)
  "Return t if cursor is at the end of SCANNER's input."
  (eq (scanner/cursor scanner)
      (length (scanner/input scanner))))

(defun scanner/next (scanner)
  "Push SCANNER's cursor one character."
  (if (scanner/eos scanner)
      (scanner/error scanner "EOF")
    (scanner/cursor/incr scanner)))

(defun scanner/any (scanner)
  "Match any character on SCANNER's input minus EOF."
  (let ((current (scanner/current scanner)))
    (scanner/next scanner)
    current))

(defun scanner/match (scanner c)
  "Match current character under SCANNER's to C."
  (if (eq c (scanner/current scanner))
      (progn (scanner/next scanner) c)
    (scanner/error scanner
     (format
      "Expected %s, got %s" c (scanner/current scanner)))))

(defun scanner/matchs (scanner s)
  "Match SCANNER's input to string S."
  (mapcar #'(lambda (i) (scanner/match scanner i)) s))

(defun scanner/range (scanner a b)
  "Succeed if SCANNER's current entry is between A and B."
  (let ((c (scanner/current scanner)))
    (if (and (>= c a) (<= c b))
        (scanner/any scanner)
      (scanner/error scanner (format "Expected %s-%s, got %s" a b c)))))

(defun scanner/or (scanner options)
  "SCANNER OPTIONS."
  (if (null options)
      (scanner/error scanner "No valid options")
    (let ((cursor (scanner/cursor scanner)))
      (condition-case nil
          (funcall (car options))
        (templatel-error
         (progn (scanner/cursor/set scanner cursor)
                (scanner/or scanner (cdr options))))))))

(defun scanner/not (scanner expr)
  "SCANNER EXPR."
  (let* ((cursor (scanner/cursor scanner))
         (succeeded (condition-case nil
                        (funcall expr)
                      (templatel-error
                       nil))))
    (scanner/cursor/set scanner cursor)
    (if succeeded
        (scanner/error scanner "Not meant to succeed")
      t)))

(defun scanner/zero-or-more (scanner expr)
  "SCANNER EXPR."
  (let ((item (condition-case nil
                  (funcall expr)
                (templatel-error nil))))
    (if (null item)
        item
      (cons item (scanner/zero-or-more scanner expr)))))

(defun scanner/one-or-more (scanner expr)
  "SCANNER EXPR."
  (cons (funcall expr)
        (scanner/zero-or-more scanner expr)))

(defun token/expr-op (scanner)
  "Read '{{' off SCANNER's input."
  (scanner/matchs scanner "{{")
  (parser/_ scanner))

(defun token/expr-cl (scanner)
  "Read '}}' off SCANNER's input."
  (scanner/matchs scanner "}}")
  (parser/_ scanner))

(defun token/stm-op (scanner)
  "Read '{%' off SCANNER's input."
  (scanner/matchs scanner "{%")
  (parser/_ scanner))

(defun token/stm-cl (scanner)
  "Read '%}' off SCANNER's input."
  (scanner/matchs scanner "%}")
  (parser/_ scanner))

(defun token/dot (scanner)
  "Read '.' off SCANNER's input."
  (scanner/matchs scanner ".")
  (parser/_ scanner))

(defun token/if (scanner)
  "Read 'if' off SCANNER's input."
  (scanner/matchs scanner "if")
  (parser/_ scanner))

(defun token/elif (scanner)
  "Read 'elif' off SCANNER's input."
  (scanner/matchs scanner "elif")
  (parser/_ scanner))

(defun token/else (scanner)
  "Read 'else' off SCANNER's input."
  (scanner/matchs scanner "else")
  (parser/_ scanner))

(defun token/endif (scanner)
  "Read 'endif' off SCANNER's input."
  (scanner/matchs scanner "endif")
  (parser/_ scanner))

(defun parser/join-chars (chars)
  "Join all the CHARS forming a string."
  (string-join (mapcar 'byte-to-string chars) ""))



;; --- Parser ---

;; Template      <- _ (Text / Statement / Expression)*
(defun parser/template (scanner)
  "Parse Template entry from SCANNER's input."
  (parser/_ scanner)
  (cons
   "Template"
   (scanner/zero-or-more
    scanner
    #'(lambda() (scanner/or
            scanner
            (list #'(lambda() (parser/text scanner))
                  #'(lambda() (parser/statement scanner))
                  #'(lambda() (parser/expression scanner))))))))

;; Text <- (!(_EXPR_OPEN / _STM_OPEN) .)+
(defun parser/text (scanner)
  "Parse Text entries from SCANNER's input."
  (cons
   "Text"
   (parser/join-chars
    (scanner/one-or-more
     scanner
     #'(lambda()
         (scanner/not
          scanner
          (lambda()
            (scanner/or
             scanner
             (list
              #'(lambda() (token/expr-op scanner))
              #'(lambda() (token/stm-op scanner))))))
         (scanner/any scanner))))))

;; Statement     <- IfStatement / ForStatement
(defun parser/statement (scanner)
  "Parse a statement from SCANNER."
  (scanner/or
   scanner
   (list
    #'(lambda() (parser/if-stm scanner))
    ;#'(lambda() (parser/for-stm scanner))
    )))

;; IfStatement   <- _If Expr _STM_CLOSE Template Elif
;;                / _If Expr _STM_CLOSE Template Else
;;                / _If Expr _STM_CLOSE Template _EndIf
(defun parser/if-stm (scanner)
  "SCANNER."
  (scanner/or
   scanner
   (list ;#'(lambda() (parser/if-stm-elif scanner))
         #'(lambda() (parser/if-stm-else scanner))
         #'(lambda() (parser/if-stm-endif scanner)))))

;; _If Expr _STM_CLOSE Template Elif
(defun parser/if-stm-elif (scanner)
  "Parse elif from SCANNER."
  (parser/if scanner)
  (let* ((expr (parser/expr scanner))
         (_ (token/stm-cl scanner))
         (tmpl (parser/template scanner))
         (elif (parser/elif scanner)))
    (cons "IfStatement" (append expr tmpl elif))))

;; _If Expr _STM_CLOSE Template Else
(defun parser/if-stm-else (scanner)
  "Parse else from SCANNER."
  (parser/if scanner)
  (let* ((expr (parser/expr scanner))
         (_ (token/stm-cl scanner))
         (tmpl (parser/template scanner))
         (else (parser/else scanner)))
    (cons "IfElse" (list expr tmpl else))))

;; _If Expr _STM_CLOSE Template _EndIf
(defun parser/if-stm-endif (scanner)
  "Parse endif from SCANNER."
  (parser/if scanner)
  (let* ((expr (parser/expr scanner))
         (_    (token/stm-cl scanner))
         (tmpl (parser/template scanner))
         (_    (parser/endif scanner)))
    ;; (message "---- E: %s: " expr)
    ;; (message "---- T: %s: " tmpl)
    ;; (message "---- A: %s: " (list expr tmpl))
    (cons "IfStatement" (list expr tmpl))))

;; Elif          <- _STM_OPEN _elif Expr _STM_CLOSE Template (Else / _EndIf)
(defun parser/elif (scanner)
  "Parse elif expression off SCANNER."
  (token/stm-op scanner)
  (token/elif scanner)
  (let ((expr (parser/expr scanner))
        (_    (token/stm-cl scanner))
        (tmpl (parser/template scanner)))
    (cons
     "Elif"
     (append
      expr
      tmpl
      (scanner/or
       scanner
       (list
        #'(lambda() (parser/else scanner))
        #'(lambda() (parser/endif scanner))))))))

;; _If           <- _STM_OPEN _if
(defun parser/if (scanner)
  "Parse if condition off SCANNER."
  (token/stm-op scanner)
  (token/if scanner))

;; Else          <- _STM_OPEN _else _STM_CLOSE Template _EndIf
(defun parser/else (scanner)
  "Parse else expression off SCANNER."
  (token/stm-op scanner)
  (token/else scanner)
  (token/stm-cl scanner)
  (let ((tmpl (parser/template scanner)))
    (parser/endif scanner)
    (cons "Else" (list tmpl))))

;; _EndIf        <- _STM_OPEN _endif _STM_CLOSE
(defun parser/endif (scanner)
  "Parse endif tag off SCANNER."
  (token/stm-op scanner)
  (token/endif scanner)
  (token/stm-cl scanner))

;; Expression    <- _EXPR_OPEN Expr _EXPR_CLOSE
(defun parser/expression (scanner)
  "SCANNER."
  (token/expr-op scanner)
  (let ((expr (parser/expr scanner)))
    (token/expr-cl scanner)
    (cons "Expression" (list expr))))

;; Expr          <- (Value / Identifier) Attribute*
(defun parser/expr (scanner)
  "Read an expression from SCANNER."
  (cons
   "Expr"
   (cons (scanner/or
          scanner
          (list #'(lambda() (parser/value scanner))
                #'(lambda() (parser/identifier scanner))))
         (scanner/zero-or-more
          scanner
          #'(lambda() (parser/attribute scanner))))))

;; Attribute     <- _dot Expr
(defun parser/attribute (scanner)
  "Read an Attribute from SCANNER."
  (token/dot scanner)
  (cons "Attribute" (parser/expr scanner)))

;; Value         <- (Number / BOOL / NIL / String)
(defun parser/-value (scanner)
  "Read value off SCANNER."
  (scanner/or
   scanner
   (list
    #'(lambda() (parser/number scanner))
    #'(lambda() (parser/bool scanner))
    #'(lambda() (parser/nil scanner))
    #'(lambda() (parser/string scanner)))))

(defun parser/value (scanner)
  "Read Value from SCANNER."
  (cons
   "Value"
   (let ((value (parser/-value scanner)))
     (parser/_ scanner)
     value)))

;; Number        <- BIN / HEX / FLOAT / INT
(defun parser/number (scanner)
  "Read Number off SCANNER."
  (cons
   "Number"
   (parser/join-chars
    (scanner/or
     scanner
     (list
      #'(lambda() (parser/bin scanner))
      #'(lambda() (parser/hex scanner))
      #'(lambda() (parser/float scanner))
      #'(lambda() (parser/int scanner)))))))

;; INT           <- [0-9]+                  _
(defun parser/int (scanner)
  "Read integer off SCANNER."
  (scanner/one-or-more
   scanner
   #'(lambda() (scanner/range scanner ?0 ?9))))

;; FLOAT         <- [0-9]* '.' [0-9]+       _
(defun parser/float (scanner)
  "Read float from SCANNER."
  (append
   (scanner/zero-or-more scanner #'(lambda() (scanner/range scanner ?0 ?9)))
   (scanner/matchs scanner ".")
   (scanner/one-or-more scanner #'(lambda() (scanner/range scanner ?0 ?9)))))

;; BIN           <- '0b' [0-1]+             _
(defun parser/bin (scanner)
  "Read binary number from SCANNER."
  (append
   (scanner/matchs scanner "0b")
   (scanner/one-or-more
    scanner
    #'(lambda() (scanner/range scanner ?0 ?1)))))

;; HEX           <- '0x' [0-9a-fA-F]+       _
(defun parser/hex (scanner)
  "Read hex number from SCANNER."
  (append
   (scanner/matchs scanner "0x")
   (scanner/one-or-more
    scanner
    #'(lambda()
        (scanner/or
         scanner
         (list #'(lambda() (scanner/range scanner ?0 ?9))
               #'(lambda() (scanner/range scanner ?a ?f))
               #'(lambda() (scanner/range scanner ?A ?F))))))))

;; BOOL          <- ('true' / 'false')         _
(defun parser/bool (scanner)
  "Read boolean value from SCANNER."
  (cons
   "Bool"
   (scanner/or
    scanner
    (list #'(lambda() (scanner/matchs scanner "true") t)
          #'(lambda() (scanner/matchs scanner "false") nil)))))

;; NIL           <- 'nil'                      _
(defun parser/nil (scanner)
  "Read nil constant from SCANNER."
  (scanner/matchs scanner "nil")
  (cons "Nil" nil))

;; String        <- _QUOTE (!_QUOTE .)* _QUOTE _
(defun parser/string (scanner)
  "Read a double quoted string from SCANNER."
  (scanner/match scanner ?\")
  (let ((str (scanner/zero-or-more
              scanner
              #'(lambda()
                  (scanner/not
                   scanner
                   #'(lambda() (scanner/match scanner ?\")))
                  (scanner/any scanner)))))
    (scanner/match scanner ?\")
    (parser/_ scanner)
    (cons "String" (parser/join-chars str))))

;; IdentStart    <- [a-zA-Z_]
(defun parser/identstart (scanner)
  "Read the first character of an identifier from SCANNER."
  (scanner/or
   scanner
   (list #'(lambda() (scanner/range scanner ?a ?z))
         #'(lambda() (scanner/range scanner ?A ?Z))
         #'(lambda() (scanner/match scanner ?_)))))

;; IdentCont    <- [a-zA-Z0-9_]*  _
(defun parser/identcont (scanner)
  "Read the rest of an identifier from SCANNER."
  (scanner/zero-or-more
   scanner
   #'(lambda()
       (scanner/or
        scanner
        (list #'(lambda() (scanner/range scanner ?a ?z))
              #'(lambda() (scanner/range scanner ?A ?Z))
              #'(lambda() (scanner/range scanner ?0 ?9))
              #'(lambda() (scanner/match scanner ?_)))))))

;; Identifier   <- IdentStart IdentCont
(defun parser/identifier (scanner)
  "Read Identifier entry from SCANNER."
  (cons
   "Identifier"
   (let ((identifier (parser/join-chars
                      (cons (parser/identstart scanner)
                            (parser/identcont scanner)))))
     (parser/_ scanner)
     identifier)))

;; _               <- (Space / Comment)*
(defun parser/_ (scanner)
  "Read whitespaces from SCANNER."
  (scanner/zero-or-more
   scanner
   #'(lambda()
       (scanner/or
        scanner
        (list
         #'(lambda() (parser/space scanner))
         #'(lambda() (parser/comment scanner)))))))

;; Space           <- ' ' / '\t' / _EOL
(defun parser/space (scanner)
  "Consume spaces off SCANNER."
  (scanner/or
   scanner
   (list
    #'(lambda() (scanner/matchs scanner " "))
    #'(lambda() (scanner/matchs scanner "\t"))
    #'(lambda() (parser/eol scanner)))))

;; _EOL            <- '\r\n' / '\n' / '\r'
(defun parser/eol (scanner)
  "Read end of line from SCANNER."
  (scanner/or
   scanner
   (list
    #'(lambda() (scanner/matchs scanner "\r\n"))
    #'(lambda() (scanner/matchs scanner "\n"))
    #'(lambda() (scanner/matchs scanner "\r")))))

;; Comment         <- "{#" (!"#}" .)* "#}"
(defun parser/comment (scanner)
  "Read comment from SCANNER."
  (scanner/matchs scanner "{#")
  (let ((str (scanner/zero-or-more
              scanner
              #'(lambda()
                  (scanner/not
                   scanner
                   #'(lambda() (scanner/matchs scanner "#}")))
                  (scanner/any scanner)))))
    (scanner/matchs scanner "#}")
    (cons "Comment" (parser/join-chars str))))



;; --- Compiler ---

(defun compiler/wrap (tree)
  "Compile Template node into a function with TREE as body."
  `(lambda(env)
     (with-temp-buffer
       ,@tree
       (buffer-string))))

(defun compiler/expr (tree)
  "Compile an expr from TREE."
  (compiler/run (car tree)))

(defun compiler/expression (tree)
  "Compile an expression from TREE."
  `(insert ,@(compiler/run tree)))

(defun compiler/text (tree)
  "Compile text from TREE."
  `(insert ,tree))

(defun compiler/identifier (tree)
  "Compile identifier from TREE."
  `(cdr (assoc ,tree env)))

(defun compiler/if-else (tree)
  "Compile if/else statement off TREE."
  ;; (message "ELSE: %s" tree)
  (let ((expr (car tree))
        (body (cadr tree))
        (else (cadr (caddr tree))))
    ;; (message "EXPR: %s" expr)
    ;; (message "BODY: %s" body)
    ;; (message "ELSE: %s" else)
    `(if ,(compiler/run expr)
         ,@(compiler/run body)
       ,@(compiler/run else))))

(defun compiler/if (tree)
  "Compile if statement off TREE."
  ;; (message "IF: %s" tree)
  (let ((expr (car tree))
        (body (cadr tree)))
    ;; (message "EXPR: %s" expr)
    ;; (message "BODY: %s" body)
    `(if ,(compiler/run expr)
         ,@(compiler/run body))))

(defun compiler/run (tree)
  "Compile TREE into bytecode."
  ;; (message "THIS IS TREE: %s" tree)
  (pcase tree
    (`() nil)
    (`("Template"    . ,a) (compiler/run a))
    (`("Text"        . ,a) (compiler/text a))
    (`("Identifier"  . ,a) (compiler/identifier a))
    (`("IfElse"      . ,a) (compiler/if-else a))
    (`("Expr"        . ,a) (compiler/expr a))
    (`("Expression"  . ,a) (compiler/expression a))
    (`("IfStatement" . ,a) (compiler/if a))
    ((pred listp)          (mapcar #'compiler/run tree))
    (_ (message "NOENTIENDO: `%s`" tree))))



;; --- Public API ---

(defun templatel-parse-string (input)
  "Parse INPUT into a tree."
  (let ((s (scanner/new input)))
    (parser/template s)))

(defun templatel-compile-string (input)
  "Compile INPUT to Lisp code."
  (let ((tree (templatel-parse-string input)))
    (compiler/wrap (compiler/run tree))))

(defun templatel-render-code (code env)
  "Render CODE to final output with variables from ENV."
  (funcall (eval code) env))

(defun templatel-render-string (input env)
  "Render INPUT to final output with variables from ENV."
  (let ((code (templatel-compile-string input)))
   (templatel-render-code code env)))

;; (let ((s (scanner/new "{% if x %}Stuff{{ x }}{% endif %}")))
;;   (message "%s" (compiler/run (parser/template s))))

(provide 'templatel)
;;; templatel.el ends here
