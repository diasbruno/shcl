(in-package :shcl.evaluate)

(optimization-settings)

(defparameter *umask*
  (logior sb-posix:s-irusr sb-posix:s-iwusr sb-posix:s-irgrp sb-posix:s-iroth))

(define-condition not-implemented (warning error)
  ((message
    :initarg :message
    :initform ""
    :accessor not-implemented-message
    :type string))
  (:report (lambda (c s) (format s "NOT-IMPLEMENTED ~A~%" (not-implemented-message c)))))

(defclass fd-wrapper ()
  ((fd
    :initarg :fd
    :initform (required)
    :type (or null fixnum)
    :accessor fd)))

(defclass pipe-fd (fd-wrapper)
  ((pipe
    :initarg :pipe
    :initform (required)
    :type communication-pipe)))

(defmethod shared-initialize :around ((instance fd-wrapper) slots &key)
  (declare (ignore slots))
  (let ((result (call-next-method))
        (fd (slot-value instance 'fd)))
    (fd-is-managed fd)
    (cancel-finalization instance)
    (finalize instance
              (lambda ()
                (format *error-output* "GCCLOSE ~A~%" fd)
                (forget-managed-fd fd)
                (sb-posix:close fd)))
    result))

(defun close-fd (the-fd)
  (with-slots (fd) the-fd
    (when fd
      (format *error-output* "CLOSE ~A~%" fd)
      (forget-managed-fd fd)
      (sb-posix:close fd)
      (setf fd nil)
      (cancel-finalization the-fd))))

(defclass communication-pipe ()
  ((read-end
    :initform nil
    :type (or null pipe-fd)
    :accessor read-end)
   (write-end
    :initform nil
    :type (or null pipe-fd)
    :accessor write-end)))

(defmethod shared-initialize :around ((pipe communication-pipe) slots &key)
  (let ((result (call-next-method)))
    (close-pipe pipe)
    (with-slots (read-end write-end) pipe
      (multiple-value-bind (fd-read-end fd-write-end) (sb-posix:pipe)
        (format *error-output* "PIPE ~A -> ~A~%" fd-write-end fd-read-end)
        (setf read-end (make-instance 'pipe-fd :pipe pipe :fd fd-read-end)
              write-end (make-instance 'pipe-fd :pipe pipe :fd fd-write-end))))
    result))

(defun close-pipe (pipe)
  (with-slots (read-end write-end) pipe
    (when read-end
      (close-fd read-end)
      (setf read-end nil))
    (when write-end
      (close-fd write-end)
      (setf write-end nil))))

(defmacro with-pipe ((variable-name) &body body)
  `(let ((,variable-name (make-instance 'communication-pipe)))
     (unwind-protect
          (progn ,@body)
       (close-pipe ,variable-name))))

(defclass eval-thunk ()
  ())

(defclass process (eval-thunk)
  ((exit-code)
   (pid
    :initarg :pid
    :accessor process-pid
    :type integer
    :initform (required))))

(defun process-from-pid (pid)
  (make-instance 'process :pid pid))

(defclass pipeline-process (eval-thunk)
  ((processes)))

(defun separator-par-p (separator)
  (check-type separator separator)
  (with-slots (separator-op) separator
    (when (slot-boundp separator 'separator-op)
      (typep separator-op 'par))))

(defparameter *fd-bindings* (make-hash-table))

(defparameter *fds-to-close-for-shadow* nil)

(defparameter *managed-fds* (make-hash-table))
(defun fd-is-managed (fd)
  (setf (gethash fd *managed-fds*) t))
(defun forget-managed-fd (fd)
  (remhash fd *managed-fds*))
(defun managed-fds ()
  (hash-table-keys *managed-fds*))

(defmacro shadow-fd-bindings (&body body)
  (let ((fd (gensym "FD")))
    `(let ((*fd-bindings* (copy-hash-table *fd-bindings*))
           *fds-to-close-for-shadow*)
       (unwind-protect (progn ,@body)
         (dolist (,fd *fds-to-close-for-shadow*)
           (forget-managed-fd ,fd)
           (sb-posix:close ,fd))))))

(defgeneric open-args-for-redirect (redirect))
(defmethod open-args-for-redirect ((r less))
  (declare (ignore r))
  (logior sb-posix:o-rdonly))
(defmethod open-args-for-redirect ((r great))
  (declare (ignore r))
  (logior sb-posix:o-wronly sb-posix:o-creat sb-posix:o-trunc))
(defmethod open-args-for-redirect ((r dgreat))
  (declare (ignore r))
  (logior sb-posix:o-wronly sb-posix:o-creat sb-posix:o-append))
(defmethod open-args-for-redirect ((r lessgreat))
  (declare (ignore r))
  (logior sb-posix:o-rdwr sb-posix:o-creat))

(defgeneric fd-from-description (description))
(defmethod fd-from-description ((fd integer))
  (values fd nil))
(defmethod fd-from-description ((io-file io-file))
  (with-slots (redirect filename) io-file
    (let ((fd (sb-posix:open (coerce (token-value filename) 'simple-string)
                             (open-args-for-redirect redirect)
                             *umask*)))
      (format *error-output* "OPEN ~A = ~A~%" fd filename)
      (fd-is-managed fd)
      (values fd t))))
(defmethod fd-from-description ((fd fd-wrapper))
  (values (slot-value fd 'fd) nil))

(defun bind-fd (fd description)
  (multiple-value-bind (from-fd needs-close) (fd-from-description description)
    (setf (gethash fd *fd-bindings*) from-fd)
    (when needs-close
      (push from-fd *fds-to-close-for-shadow*))))

(define-condition invalid-fd (error)
  ((fd
    :type integer
    :initarg :fd
    :accessor invalid-fd-fd
    :initform (required)))
  (:report (lambda (c s) (format s "Redirect from invalid fd: ~A~%" (invalid-fd-fd c)))))

(defun get-fd (fd)
  (when (gethash fd *managed-fds*)
    (error 'invalid-fd :fd fd))
  (let ((mapped-fd (gethash fd *fd-bindings*)))
    (when mapped-fd
      (return-from get-fd mapped-fd))

    (handler-case (sb-posix:fcntl fd sb-posix:f-getfd)
      (sb-posix:syscall-error ()
        (error 'invalid-fd :fd fd)))
    fd))

(defgeneric handle-redirect (redirect &optional fd-override))

(defmethod handle-redirect ((r io-redirect) &optional fd-override)
  (when fd-override
    (error "You did bad.  This shouldn't be set here."))

  (assert (slot-boundp r 'io-number))

  (labels
      ((to-int (io-number)
         (parse-integer (token-value io-number))))
    (with-slots (io-number io-file io-here) r
      (cond
        ((slot-boundp r 'io-here)
         (error 'not-implemented :message "Here-documents are not implemented"))

        ((slot-boundp r 'io-file)
         (handle-redirect io-file (to-int io-number)))

        (t
         (error "Impossible"))))))

(defmethod handle-redirect ((r io-file) &optional fd-override)
  (labels
      ((to-int (filename)
         (let* ((fd-string (token-value filename)))
           (parse-integer fd-string)))
       (fd (default) (or fd-override default)))
    (with-slots (redirect filename) r
      (etypecase redirect
        (less
         (bind-fd (fd 0) r))

        (lessand
         (bind-fd (fd 0) (get-fd (to-int filename))))

        (great
         (bind-fd (fd 1) r))

        (greatand
         (bind-fd (fd 1) (get-fd (to-int filename))))

        (dgreat
         (bind-fd (fd 1) r))

        (lessgreat
         (bind-fd (fd 0) r))

        (clobber
         (bind-fd (fd 1) r))))))

(defmethod handle-redirect ((r io-here) &optional fd-override)
  (declare (ignore fd-override))
  (error 'not-implemented :message "Here-documents are not implemented"))

(defmethod handle-redirect ((r redirect-list) &optional fd-override)
  (when fd-override
    (error "You did bad.  This shouldn't be set here."))

  (with-slots (io-redirect redirect-list-tail) r
    (handle-redirect io-redirect)
    (when redirect-list-tail
      (handle-redirect redirect-list-tail))))

(defmethod handle-redirect ((r redirect-list-tail) &optional fd-override)
  (when fd-override
    (error "You did bad.  This shouldn't be set here."))

  (with-slots (io-redirect redirect-list-tail) r
    (handle-redirect io-redirect)
    (when redirect-list-tail
      (handle-redirect redirect-list-tail))))

(defgeneric evaluate (syntax-tree))

(defmethod evaluate (sy)
  (error 'not-implemented :message (format nil "Cannot eval ~A" (class-name (class-of sy)))))

(defmethod evaluate ((sy complete-command))
  (with-slots (newline-list complete-command command-list command-separator) sy
    (cond
      ((and (slot-boundp sy 'newline-list)
            complete-command)
       (evaluate complete-command))

      ((slot-boundp sy 'newline-list)
       (return-from evaluate nil))

      (t
       (let ((no-wait (typep command-separator 'par)))
         (when no-wait
           (error 'not-implemented :message "& not implemented"))

         (evaluate command-list))))))

(defun evaluate-command-list (sy)
  (with-slots (and-or command-list-tail) sy
    (let ((no-wait (and command-list-tail
                        (typep (slot-value command-list-tail 'separator-op) 'par))))
      (when no-wait
        (error 'not-implemented :message "& not implemented"))

      (evaluate and-or)
      (when command-list-tail
        (evaluate command-list-tail)))))

(defmethod evaluate ((sy command-list))
  (evaluate-command-list sy))
(defmethod evaluate ((sy command-list-tail))
  (evaluate-command-list sy))

(defun evaluate-and-or (sy)
  (with-slots (pipeline and-or-tail) sy
    (evaluate pipeline)
    (when and-or-tail
      (error 'not-implemented :message "&& and || are not implemented"))))

(defmethod evaluate ((sy and-or))
  (evaluate-and-or sy))
(defmethod evaluate ((sy and-or-tail))
  (evaluate-and-or sy))

(defmethod evaluate ((sy pipeline))
  (with-slots (bang pipe-sequence) sy
    (error 'not-implemented :message "! not implemented")))

(defconstant +pipe-read-fd+ 0)
(defconstant +pipe-write-fd+ 1)

(defun evaluate-pipe-sequence (sy)
  (with-slots (command pipe-sequence-tail) sy
    (cond
      (pipe-sequence-tail
       (with-pipe (pipe)
         (with-accessors ((read-end read-end) (write-end write-end)) pipe
           (shadow-fd-bindings
             (bind-fd +pipe-write-fd+ write-end)
             (evaluate command))
           (shadow-fd-bindings
             (bind-fd +pipe-read-fd+ read-end)
             (evaluate pipe-sequence-tail)))))

      (t
       (evaluate command)))))

(defmethod evaluate ((sy pipe-sequence))
  (evaluate-pipe-sequence sy))
(defmethod evaluate ((sy pipe-sequence-tail))
  (evaluate-pipe-sequence sy))

(defmethod evaluate ((sy command))
  (with-slots (compound-command redirect-list) sy
    (shadow-fd-bindings
      (handle-redirect redirect-list)
      (evaluate compound-command))))

(defmethod evaluate ((sy subshell))
  (error 'not-implemented :message "Subshells not implemented"))

(defmethod evaluate ((sy compound-list))
  (with-slots (newline-list term separator) sy
    (when (and (slot-boundp sy 'separator)
               (separator-par-p separator))
      (error 'not-implemented :message "& not implemented"))

    (evaluate term)))

(defun evaluate-term (sy)
  (with-slots (and-or term-tail) sy
    (when (and term-tail
               (separator-par-p (slot-value term-tail 'separator)))
      (error 'not-implemented :message "& not implemented"))

    (evaluate and-or)
    (evaluate term-tail)))

(defmethod evaluate ((sy term))
  (evaluate-term sy))
(defmethod evaluate ((sy term-tail))
  (evaluate-term sy))

(defun cmd-prefix-parts (prefix)
  (with-slots (io-redirect assignment-word cmd-prefix-tail) prefix
    (multiple-value-bind (assignments redirects)
        (when cmd-prefix-tail
          (cmd-prefix-parts cmd-prefix-tail))

      (when (slot-boundp prefix 'io-redirect)
        (push io-redirect redirects))

      (when (slot-boundp prefix 'assignment-word)
        (push assignment-word assignments))

      (values assignments redirects))))

(defun cmd-suffix-parts (suffix)
  (with-slots (io-redirect a-word cmd-suffix-tail) suffix
    (multiple-value-bind (arguments redirects)
        (when cmd-suffix-tail
          (cmd-suffix-parts cmd-suffix-tail))

      (when (slot-boundp suffix 'io-redirect)
        (push io-redirect redirects))

      (when (slot-boundp suffix 'a-word)
        (push a-word arguments))

      (values arguments redirects))))

(defun simple-command-parts (sy)
  (let (assignments
        arguments
        redirects)
    (with-slots (cmd-prefix cmd-word cmd-name cmd-suffix) sy
      (when (slot-boundp sy 'cmd-prefix)
        (multiple-value-bind (prefix-assignments prefix-redirects) (cmd-prefix-parts cmd-prefix)
          (dolist (a prefix-assignments)
            (push a assignments))
          (dolist (r prefix-redirects)
            (push r redirects))))

      (when (slot-boundp sy 'cmd-name)
        (push cmd-name arguments))

      (when (slot-boundp sy 'cmd-word)
        (push cmd-word arguments))

      (when (slot-boundp sy 'cmd-suffix)
        (multiple-value-bind (suffix-arguments suffix-redirects) (cmd-suffix-parts cmd-suffix)
          (dolist (a suffix-arguments)
            (push a arguments))
          (dolist (r suffix-redirects)
            (push r redirects))))

      (values (nreverse assignments) (nreverse arguments) (nreverse redirects)))))

(defmethod evaluate ((sy simple-command))
  (with-slots (cmd-prefix cmd-word cmd-name cmd-suffix) sy
    (multiple-value-bind (assignments arguments redirects) (simple-command-parts sy)
      (format *standard-output* "EXEC: ~A ~A ~A~%" assignments arguments redirects)
      (shadow-fd-bindings
        (dolist (r redirects)
          (handle-redirect r))
        (let ((pid (fork-exec (coerce (mapcar 'token-value arguments) 'vector) :fd-map *fd-bindings* :managed-fds *managed-fds*)))
          (process-from-pid pid))))))

(define-condition not-a-thunk (warning)
  ((actual-type
    :initarg :actual-type
    :accessor not-a-thunk-actual-type
    :initform (required)
    :type symbol)
   (eval-target
    :initarg :eval-target
    :accessor not-a-thunk-eval-target
    :initform (required)))
  (:report (lambda (c s) (format s "~A is not an EVAL-THUNK.  Given ~A~%"
                                 (not-a-thunk-actual-type c) (not-a-thunk-eval-target c)))))

(defmethod evaluate :around (sy)
  (let ((result (call-next-method)))
    (unless (typep result 'eval-thunk)
      (warn 'not-a-thunk :actual-type (class-name (class-of result)) :eval-target sy))
    result))