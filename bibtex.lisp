;;; A BibTeX re-implementation in Common Lisp - the BibTeX program
;;; Copr. 2001, 2002 Matthias Koeppe <mkoeppe@mail.math.uni-magdeburg.de>
;;; This is free software, licensed under GNU GPL (see file COPYING)

(in-package bibtex-compiler)

(defconstant +version+ 0.2)

;;; The compiler front-end

(defun make-entry-type-function-alist ()
  (loop for fun being each hash-value in *bst-functions*
        when (and (member (bst-function-type fun)
                          '(wizard-defined compiled-wiz-defined))
                  (null (bst-function-argument-types fun))
                  (null (bst-function-result-types fun))
		  (side-effects-side-effects-p
		   (bst-function-side-effects fun)))
	collect (cons (bst-function-name fun)
		      (bst-function-lisp-name fun))))

(defun compile-bst-file (bst-file lisp-file)
  (let ((*bib-macros* (make-hash-table))
	(*bst-compiling* t)
	(*main-lisp-body* ())
	(*bst-functions* (builtin-bst-functions)))
    (with-open-file (*lisp-stream* lisp-file :direction :output)
      (with-open-file (bst-stream bst-file)
	(format *lisp-stream*
		";;;; This is a -*- Common-Lisp -*- program, automatically translated~%;;;; from the BibTeX style file `~A'~%;;;; by the CL-BibTeX compiler (version ~A).~%"
		(namestring bst-file) +version+)
	(let* ((package-name (concatenate 'string "BIBTEX-STYLE-"
					  (string-upcase 
					   (pathname-name bst-file))))
	       (use-list '("COMMON-LISP" "BIBTEX-RUNTIME" "BIBTEX-COMPILER"))
	       (temp-package-name (gentemp "BIBTEX-STYLE-"))
	       (temp-package (make-package temp-package-name :use use-list))
	       (*bib-entries-symbol* (intern "BIB-ENTRIES" temp-package)))
	  (unwind-protect
	       (progn
		 (lisp-write `(defpackage ,package-name
			       (:use ,@use-list)))
		 (lisp-write `(in-package ,package-name))
		 (let ((*package* temp-package))
		   (get-bst-commands-and-process bst-stream)
		   (lisp-write `(define-bibtex-style ,(pathname-name bst-file) 
				 (let ((*bib-entry-type-functions*
					',(make-entry-type-function-alist))
				       ,*bib-entries-symbol*)
				   ,@(reverse *main-lisp-body*))))))
	    (delete-package temp-package)))))))

;;; The BibTeX program

(defvar *bibtex-styles* '()
  "An alist mapping BibTeX styles (strings) to thunk designators that
implement the BibTeX style.  Use REGISTER-BIBTEX-STYLE to put items
here.")

(defvar *allow-load-lisp-bibtex-style* t
  "Non-nil if a Lisp BibTeX style is allowed to be located via
KPSEARCH and loaded into the Lisp image.  (This might be seen as a
security risk, because Lisp programs are much more powerful than BST
scripts.)")

(defun register-bibtex-style (name thunk)
  "Register a BibTeX style, implemented as THUNK (a function
designator), under NAME."
  (push (cons name thunk) *bibtex-styles*))

(defmacro define-bibtex-style (name &body body)
  (let ((function-name
	 (gentemp (concatenate 'string "BIBTEX-STYLE-" (string name)))))
    `(progn (defun ,function-name () ,@body)
      (register-bibtex-style ',name ',function-name))))      

(defun find-bibtex-style (style)
  "Find the named BibTeX STYLE.
* First try the styles registered using REGISTER-BIBTEX-STYLE.
* Then, if *ALLOW-LOAD-LISP-BIBTEX-STYLE* is true, try to find and
  load a Lisp BibTeX style file named \"STYLE.lbst\".
* Finally try to find a BibTeX style file named \"STYLE.bst\".
Return a thunk that implements the BibTeX style.  Signal an error
if no style of the requested name has been found."
  (let (it)
    (cond
      ((setq it (assoc style *bibtex-styles* :test #'string-equal))
       (cdr it))
      ((and *allow-load-lisp-bibtex-style*
	    (setq it (kpathsea:find-file
		      (make-pathname :type "LBST" :case :common
				     :defaults style))))
       (unless (load it)
	 (error "Loading Lisp BibTeX style file `~A' failed."
		it))
       ;; The Lisp BibTeX style is supposed to register the style.
       (let ((style/thunk (assoc style *bibtex-styles* :test #'string-equal)))
	 (unless style/thunk
	   (error "Lisp BibTeX style `~A' failed to register itself." style))
	 (cdr style/thunk)))
      ((setq it (kpathsea:find-file
		 (make-pathname :type "BST" :case :common
				:defaults style)))
       (lambda ()
	 (with-open-file (bst-stream it :if-does-not-exist nil)
	   (unless bst-stream
	     (bib-fatal "I couldn't open style file `~A'" it))
	   (let ((*literal-stack* nil))
	     (get-bst-commands-and-process bst-stream)))))
      (t (error "Could not find a BibTeX style named `~A'." style)))))
       
       

(defun bibtex (file-stem &key style)
  "The BibTeX program.  Read citation commands, a list of
bibliographic databases and the name of the bibliography style from
TeX commands in the file `FILE-STEM.aux'.  Find the named bibliography
style via `find-bibtex-style'; it can be overridden programmatically
using the :STYLE argument (a string or a function).  Print the
formatted bibliography to the file `FILE-STEM.bbl'."
  (let ((*bib-macros* (make-hash-table))
	(*bib-database* (make-hash-table :test #'equalp))
	(*bib-preamble* "")
	(*bib-entries* ())
	(*bib-files* ())
	(*cite-all-entries* nil)
	(*cite-keys* ())
	(*history* +spotless-history+)
	(*err-count* 0)
	(*bib-style* nil)
	(*bst-functions* (builtin-bst-functions)))	
    (read-aux-file (make-pathname :type "AUX" :case :common
				  :defaults file-stem))
    (let ((style-function
	   (cond
	     ((not style) (find-bibtex-style *bib-style*))
	     ((functionp style) style)
	     ((stringp style) (find-bibtex-style style))
	     (t (error "Bad :STYLE argument: ~S" style)))))
      (with-open-file (*bbl-output* (make-pathname :type "BBL" :case :common
						   :defaults file-stem)
				    :direction :output)
	(funcall style-function)))))

;;;;

#|
(defun f ()
  (let ((s (open "/usr/share/texmf/bibtex/bst/base/abbrv.bst"))
	(*bibtex-split-initials* t)
	(*bst-compiling* nil)
	(*bib-macros* (make-hash-table))
	(*bib-database* (make-hash-table :test #'equalp))
	(*bib-files* '("/home/mkoeppe/cvs/iba-papers/iba-bib.bib"))
	(*cite-all-entries* t)
	(*cite-keys* nil)
	(*bib-entries* nil))
    (get-bst-commands-and-process s)))

(let ((*readtable* *bst-readtable*))
  (read s))

(let ((*readtable* *bst-readtable*))
  (read-from-string "a:b"))

(defvar s (open "/tmp/x"))

(let ((*readtable* *bst-readtable*))
  (read s))

(with-input-from-string (s "\"a\\ebc\"")
  (read s))

(bibtex "ibm-theory")

(progn
  (setf (ext:default-directory) "/home/mkoeppe/w/iba-papers/")
  (let ((*lexicals* '("NUMNAMES" "NAMESLEFT" "NAMEPTR" "S" "T" "LEN" "MULTIRESULT")))
    (compile-bst-file (kpathsea:find-file "amsalpha.bst")
		      "/tmp/compiled-bst.lisp"))
  (load "/tmp/compiled-bst.lisp" :if-source-newer :compile)
  (cl-bibtex "ibm-theory" 'amsalpha))

(let ((*lexicals* '("NUMNAMES" "NAMESLEFT" "NAMEPTR" "S" "T" "LEN" "MULTIRESULT")))
    (compile-bst-file "/home/mkoeppe/w/diss/diss.bst"
		      "/tmp/compiled-bst.lisp"))

(compile-bst-file "test.bst"
		  "/tmp/compiled-bst.lisp")

|#

