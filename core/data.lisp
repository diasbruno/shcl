;; Copyright 2017 Bradley Jensen
;;
;; Licensed under the Apache License, Version 2.0 (the "License");
;; you may not use this file except in compliance with the License.
;; You may obtain a copy of the License at
;;
;;     http://www.apache.org/licenses/LICENSE-2.0
;;
;; Unless required by applicable law or agreed to in writing, software
;; distributed under the License is distributed on an "AS IS" BASIS,
;; WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
;; See the License for the specific language governing permissions and
;; limitations under the License.

(defpackage :shcl/core/data
  (:use :common-lisp :shcl/core/utility)
  (:import-from :closer-mop)
  (:import-from :fset)
  (:export #:define-data))
(in-package :shcl/core/data)

(optimization-settings)

(defmacro define-cloning-accessor (name &key slot-name accessor)
  "Define a non-destructive reader and setf-expander.

Immutable data structures can be very useful, but they can also be
pretty annoying when you want to update them.  Your only option is to
create a new copy of the data structure which reflects the changes you
want and then update your variable to point at the new version.  This
macro makes that processs easier and more fluent by allowing you to
use the `setf' macro to do it.

This only works if you provide a method for `clone' specialized on the
appropriate type."
  (unless (and (or slot-name accessor) (not (and slot-name accessor)))
    (error "define-cloning-accessor requires either a slot-name xor an accessor function"))
  (let* ((object (gensym "OBJECT"))
         (env (gensym "ENV"))
         (vars (gensym "VARS"))
         (vals (gensym "VALS"))
         (set-vars (gensym "SET-VARS"))
         (setter (gensym "SETTER"))
         (getter (gensym "GETTER"))
         (inner-clone (gensym "INNER-CLONE"))
         (set-var (gensym "SET-VAR"))
         ;; AAAAH nested backquotes are hard!  I couldn't figure out
         ;; how to get the appropriate accessor form into the setf
         ;; expander forms.  This is a bit hacky, but it works, damn
         ;; it!
         (access-macro (gensym "ACCESS-MACRO"))
         (access-wrapper
          (if slot-name
              (list `(defmacro ,access-macro (,object)
                       `(slot-value ,,object ,'',slot-name)))
              (list `(defmacro ,access-macro (,object)
                       `(,',accessor ,,object))))))
    `(progn
       ,@access-wrapper
       (defun ,name (,object)
         (,access-macro ,object))
       (define-setf-expander ,name (,object &environment ,env)
         (multiple-value-bind (,vars ,vals ,set-vars ,setter ,getter) (get-setf-expansion ,object ,env)
           (let ((,inner-clone (gensym "INNER-CLONE"))
                 (,set-var (gensym "SET-VAR")))
             (values
              `(,@,vars ,,inner-clone)
              `(,@,vals (clone ,,getter))
              `(,,set-var)
              `(progn
                 (setf (,',access-macro ,,inner-clone) ,,set-var)
                 (multiple-value-bind ,,set-vars ,,inner-clone
                   ,,setter)
                 ,,set-var)
              `(,',access-macro ,,inner-clone))))))))

(defun clone-slots (slots old new)
  "For each given slot name, store `old''s value in `new'."
  (dolist (slot slots)
    (setf (slot-value new slot) (slot-value old slot)))
  new)

(defgeneric clone (object)
  (:documentation
   "Create a clone of the given object which contains the same data.

If you wish to use `define-cloning-accessor' to access parts of a
type, you must define a method for that type which returns an object
which is not `eq' to the input object."))
(defmethod clone (object)
  object)

(defclass data-class (standard-class)
  ()
  (:documentation
   "This metaclass provides a way to silo-off purely-data-like classes
from the wild west of normal classes.

If your class uses this metaclass, then your class will only be
allowed participate in an inheritance relationship with other
`data-class' classes.  As a result, you don't have to worry about
nasty un-data-like behaviors slipping into your pure and innocent
data-like class.

All `data-class' instances must have the `data' class in their class
precedence list."))

(defclass data ()
  ()
  (:documentation
   "Classes which inherit from `data' will be treated like they are plain
old data.

Plain old data will be manipulated in a very slot-centric way.  For
example...
- `clone' will just mirror all slots into a fresh instance
- `fset:compare' will recursively compare slots
- `make-load-form' will simply store slot values

If these sorts of operations are inappropriate for your class, you
must not inherit from `data'."))

(defmethod clone ((object data))
  (clone-slots (mapcar 'closer-mop:slot-definition-name (closer-mop:class-slots (class-of object)))
               object
               (make-instance (class-of object))))

(defmethod fset:compare ((first data) (second data))
  (labels
      ((slot-names (slots)
         (mapcar 'closer-mop:slot-definition-name slots))
       (compare-slots (slots)
         (let ((result :equal))
           (dolist (slot slots)
             (ecase (fset:compare (slot-value first slot) (slot-value second slot))
               (:less
                (return-from compare-slots :less))
               (:greater
                (return-from compare-slots :greater))
               (:unequal
                (setf result :unequal))
               (:equal)))
           result)))
    (declare (dynamic-extent #'compare-slots #'slot-names))

    ;; Same class?  We can compare them!
    (when (eq (class-of first) (class-of second))
      (return-from fset:compare
        (compare-slots (slot-names (closer-mop:class-slots (class-of first))))))

    ;; Subtype?  Let's compare what we can!  Subtypes are greater than
    ;; supertypes
    (when (typep second (type-of first))
      (let ((result (compare-slots (slot-names (closer-mop:class-slots (class-of first))))))
        (return-from fset:compare
          (if (eq :equal result)
              :less
              result))))

    ;; Same as above
    (when (typep first (type-of second))
      (let ((result (compare-slots (slot-names (closer-mop:class-slots (class-of second))))))
        (return-from fset:compare
          (if (eq :equal result)
              :greater
              result))))

    ;; Worst case.  Let's compare the slots that we can.  They might
    ;; have some common ones.
    (let* ((first-slots (slot-names (closer-mop:class-slots (class-of first))))
           (second-slots (slot-names (closer-mop:class-slots (class-of second))))
           (common-slots (intersection first-slots second-slots))
           (result (compare-slots common-slots)))
      (return-from fset:compare
        (if (eq :equal result)
            :unequal
            result)))))

(defmethod make-load-form ((object data) &optional environment)
  (make-load-form-saving-slots
   object
   :slot-names (mapcar 'closer-mop:slot-definition-name (closer-mop:class-slots (class-of object)))
   :environment environment))

(defmethod closer-mop:validate-superclass ((data-class data-class) superclass)
  (if (or (eq superclass (find-class 'standard-object))
          (eq superclass (find-class 'data)))
      t
      (call-next-method)))

(defmethod closer-mop:finalize-inheritance :after ((class data-class))
  (let* ((superclasses (closer-mop:class-precedence-list class)))
    (unless (member (find-class 'data) superclasses)
      (error "data classes must inherit from data"))))

(defmacro define-data (name direct-superclasses direct-slots &rest options)
  "Define a class which is assumed to behave like plain old data.

This macro works just like `defclass' with a few modifications.

1. The metaclass is always `data-class'.  See the documentation for
   `data-class' to learn more about the implications of this.

2. The class will inherit from `data' if no superclass is specified.
   An error will be signaled if the class you are attempting to define
   doesn't have `data' in its class precedence list.  See the
   documentation for `data' to learn more about the implications of
   being a subclass of `data'.

3. Slot definitions may now include the `:updater' argument to define
   a cloning accessor with `define-cloning-accessor'.  See the
   documentation for `define-cloning-accessor' to learn more about how
   they behave."
  (when (find :metaclass options :key #'car)
    (error "metaclass option is forbidden"))
  (unless direct-superclasses
    (setf direct-superclasses '(data)))
  (let (updaters)
    (labels
        ((normalize-slot-definition (definition)
           (when (symbolp definition)
             (return-from normalize-slot-definition definition))
           (let ((slot-name (car definition))
                 (remaining (cdr definition))
                 cleaned)
             (loop :while remaining :do
                (progn
                  (unless (cdr remaining)
                    (error "odd number of elements in &key list for slot definition"))
                  (destructuring-bind (key value &rest rest) remaining
                    (cond
                      ((eq key :updater)
                       (push (cons value slot-name) updaters))
                      (t
                       (push key cleaned)
                       (push value cleaned)))
                    (setf remaining rest))))
             (cons slot-name (nreverse cleaned))))
         (updater-form (updater-description)
           `(define-cloning-accessor ,(car updater-description) :slot-name ,(cdr updater-description))))
      (setf direct-slots (mapcar #'normalize-slot-definition direct-slots))
      `(progn
         (defclass ,name ,direct-superclasses ,direct-slots
           (:metaclass data-class)
           ,@options)
         ,@(mapcar #'updater-form updaters)
         ',name))))
