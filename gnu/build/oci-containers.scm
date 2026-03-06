;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2025 Giacomo Leidi <goodoldpaul@autistici.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;;
;;; This module contains helpers used as part of the oci-service-type
;;; definition.
;;;
;;; Code:

(define-module (gnu build oci-containers)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (ice-9 popen)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:export (oci-read-lines
            oci-system*
            oci-object-exists?
            oci-object-service-available?
            oci-image-load
            oci-log-verbose
            oci-container-execlp
            oci-object-create))

(define (oci-log level port format-string . args)
  (define log-level
    (format #f "[~a] " (string-upcase (symbol->string level))))
  (define message
    (apply format `(#f ,format-string ,@args)))
  (format port "~a~a" log-level message))

(define* (oci-log-debug log-port format-string . args)
  (apply oci-log `(debug ,log-port ,format-string ,@args)))
(define* (oci-log-info log-port format-string . args)
  (apply oci-log `(info ,log-port ,format-string ,@args)))

(define* (oci-read-lines invocation
                         #:key verbose?
                         (log-port (current-error-port)))
  (define (get-lines port)
    (let ((lines-string (get-string-all port)))
      (string-split lines-string #\newline)))

  (define command
   (string-join invocation " "))

  (when verbose?
    (oci-log-debug log-port "Running ~a~%" command))

  (with-input-from-port (open-input-pipe command)
    (lambda _
      (get-lines (current-input-port)))))

(define* (oci-log-verbose invocation
                          #:key (log-port (current-error-port)))
  (oci-log-debug log-port "Running in verbose mode...
Current user: ~a ~a
Current group: ~a ~a
Current directory: ~a~%"
          (getuid) (passwd:name (getpwuid (getuid)))
          (getgid) (group:name (getgrgid (getgid)))
          (getcwd))

  (oci-log-debug log-port "Running~{ ~a~}~%" invocation))

(define* (oci-system* invocation
                      #:key verbose?
                      (log-port (current-error-port)))
  (when verbose?
    (oci-log-debug log-port "Running~{ ~a~}~%" invocation))

  (let* ((status (apply system* invocation))
         (exit-code (status:exit-val status)))
    (when verbose?
      (oci-log-debug log-port "Exit code: ~a~%" exit-code))
    status))

(define* (oci-object-member name objects
                            #:key verbose?
                            (log-port (current-error-port)))

  (define member? (member name objects))

  (when (and verbose? (> (length objects) 0))
    (oci-log-debug log-port "~a is ~apart of:~{ ~a~}~%"
                   name
                   (if member? "" "not ")
                   objects))
  member?)

(define* (oci-object-list runtime-cli object
                          #:key verbose?
                          (format-string "{{.Name}}")
                          (log-port (current-error-port)))

  (define invocation
    (list runtime-cli object "ls" "--format"
          (string-append "\"" format-string "\"")))

  (filter
   (lambda (name)
     (not (string=? (string-trim name) "")))
   (oci-read-lines invocation #:verbose? verbose?)))

(define* (docker-object-exist? runtime-cli object name
                               #:key verbose?
                               (format-string "{{.Name}}")
                               (log-port (current-error-port)))

  (define objects
    (oci-object-list runtime-cli object
                     #:verbose? verbose?
                     #:format-string format-string))

  (oci-object-member name objects #:verbose? verbose?))

(define* (podman-object-exist? runtime-cli object name
                               #:key verbose?
                               (log-port (current-error-port)))
  (let ((invocation (list runtime-cli object "exists" name)))
    (define exit-code
      (status:exit-val (oci-system* invocation #:verbose? verbose?)))
    (equal? EXIT_SUCCESS exit-code)))

(define* (oci-object-exists? runtime runtime-cli object name
                             #:key verbose?
                             (format-string "{{.Name}}")
                             (log-port (current-error-port)))
  (if (eq? runtime 'podman)
      (podman-object-exist? runtime-cli object name
                            #:verbose? verbose?)
      (docker-object-exist? runtime-cli object name
                            #:verbose? verbose?
                            #:format-string format-string)))

(define* (oci-object-service-available? runtime-cli object names
                                        #:key verbose?
                                        (format-string "{{.Name}}")
                                        (log-port (current-error-port)))
  "Whether NAMES are provisioned in the current OBJECT environment."
  (define environment
    (oci-object-list runtime-cli object
                     #:verbose? verbose?
                     #:format-string format-string))
  (when verbose?
    (oci-log-debug log-port "~a environment:~{ ~a~}~%" object environment))

  (define available?
    (every
     (lambda (name)
       (oci-object-member name environment #:verbose? verbose?))
     names))

  (when verbose?
   (oci-log-debug log-port "~a service is~a available~%" object (if available? "" " not")))

  available?)

(define* (oci-image-load runtime runtime-cli tarball name tag
                         #:key verbose?
                         (format-string "{{.Repository}}:{{.Tag}}")
                         (log-port (current-error-port)))
  (define load-invocation
    (list runtime-cli "load" "-i" tarball))

  (if (oci-object-exists? runtime runtime-cli "image" tag
                          #:verbose? verbose?
                          #:format-string format-string)
      (oci-log-info log-port "~a image already exists, skipping.~%" tag)
      (begin
        (oci-log-info log-port "Loading image for ~a from ~a...~%" name tarball)

        (let ((line (first
                     (oci-read-lines load-invocation #:verbose? verbose?))))
          (unless (or (eof-object? line)
                      (string-null? line))

            (format log-port "~a~%" line)

            (let* ((repository&tag
                    (string-drop line
                                 (string-length
                                  "Loaded image: ")))
                   (tag-invocation
                    (list runtime-cli "tag" repository&tag tag))
                   (drop-old-tag-invocation
                    (list runtime-cli "image" "rm" "-f" repository&tag)))

              (unless (string=? repository&tag tag)
                (let ((exit-code
                       (status:exit-val
                        (oci-system* tag-invocation #:verbose? verbose?))))
                  (oci-log-info log-port "Tagged ~a with ~a...~%" tarball tag)

                  (when (equal? EXIT_SUCCESS exit-code)
                    (oci-system* drop-old-tag-invocation #:verbose? verbose?))))))))))

(define* (oci-container-execlp invocation
                               #:key verbose? pre-script
                               (log-port (current-error-port)))
  (when pre-script
    (pre-script))
  (when verbose?
    (oci-log-verbose invocation))
  (apply execlp (first invocation) invocation))

(define* (oci-object-create runtime runtime-cli runtime-name
                            object
                            invocations
                            #:key verbose?
                            (format-string "{{.Name}}")
                            (log-port (current-error-port)))
  (for-each
   (lambda (invocation)
     (define name (last invocation))
     (if (oci-object-exists? runtime runtime-cli object name
                             #:format-string format-string
                             #:verbose? verbose?)
         (oci-log-info log-port "~a ~a ~a already exists, skipping creation.~%"
                       runtime-name name object)
         (oci-system* invocation #:verbose? verbose?)))
   invocations))
