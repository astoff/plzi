;;; plz-see.el --- Interactive HTTP client              -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Augusto Stoffel

;; Author: Augusto Stoffel <arstoffel@gmail.com>
;; Keywords: comm, network, http

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; 

;;; Code:

(require 'json)
(require 'plz)

;;; User options and variables

(defgroup plz-see nil
  "Interactive HTTP client."
  :group 'plz
  :link '(url-link "https://github.com/astoff/plz-see.el"))

(defcustom plz-see-base-url nil
  "Prefix to add to the URL argument of `plz-see', if relative.
Here \"relative\" means, paradoxically, that the URL in question
starts with '/'."
  :local t
  :type '(choice string (const :tag "None" nil))
  :safe #'stringp)

(defcustom plz-see-base-headers nil
  "List of headers to add to all requests.
Entries of this alist are ignored if the same header is given
explicitly in the HEADERS argument of `plz-see'."
  :local t
  :type '(alist :key-type string :value-type string)
  :safe #'listp)

(defcustom plz-see-keep-buffers 10
  "How many response buffers to keep.
If nil, never delete old response buffers."
  :type '(choice natnum (const :tag "Keep all" nil)))

(defcustom plz-see-display-action nil
  "The ACTION argument `plz-see' passes to `display-buffer'."
  :type 'sexp)

(defcustom plz-see-header-line-format
  (let ((headers '(plz-see-header-line-status
                   plz-see-header-line-content-type
                   plz-see-header-line-content-length
                   plz-see-header-line-show-headers)))
    (dolist (sym headers)
      (put sym 'risky-local-variable t))
    (cons "" headers))
  "Header line format for `plz-see' result buffers."
  :type 'sexp)

(defcustom plz-see-headers-buffer nil
  "Buffer used to display request headers.
This can be nil to add the headers to the response buffer itself,
or a buffer name to use a separate buffer."
  :type 'sexp)

(defface plz-see-header '((t :inherit font-lock-comment-face))
  "Face added by `plz-see-insert-headers' to response headers.")

(defcustom plz-see-content-type-alist
  `(("\\`text/html" . html-mode)
    ("\\`\\(application\\|text\\)/xml" . xml-mode)
    ("\\`application/xhtml\\+xml" . xml-mode)
    ("\\`application/json" . ,(lambda ()
                                (json-pretty-print-buffer)
                                (js-json-mode)))
    ("\\`application/javascript" . js-mode)
    ("\\`application/css" . css-mode)
    ("\\`text/plain" . text-mode)
    ("\\`application/pdf" . doc-view-mode)
    ("\\`image/" . image-mode))
  "Alist mapping content types to rendering functions."
  :type '(alist :key-type regexp
                :value-type function))

(defvar-local plz-see-response nil
  "Store the `plz-response' object in a `plz-see' buffer.")

(defvar plz-see--buffers '(0 . nil)
  "List of buffers generated by `plz-see'.
The car is the number of buffers created so far.")

;;; Response buffer header line

(defvar plz-see-header-line-status
  '(:eval
    (setq-local plz-see-header-line-status
                (format "HTTP/%s %s"
                        (plz-response-version plz-see-response)
                        (let ((status (plz-response-status plz-see-response)))
                          (propertize (number-to-string status)
                                      'face (if (<= 200 status 299) 'success 'error)))))))

(defvar plz-see-header-line-content-type
  '(:eval
    (setq-local plz-see-header-line-content-type
                (when-let ((ct (alist-get 'content-type
                                          (plz-response-headers plz-see-response))))
                  (format " | %s" ct)))))

(defvar plz-see-header-line-content-length
  '(:eval
    (setq-local plz-see-header-line-content-length
                (when-let ((len (alist-get 'content-length
                                           (plz-response-headers plz-see-response))))
                  (format " | %s bytes" len)))))

(defvar plz-see-header-line-show-headers
  '(:eval
    (setq-local plz-see-header-line-show-headers
                (format " | %s"
                        (buttonize "show headers"
                                   (lambda (buffer)
                                     (with-selected-window (get-buffer-window buffer)
                                       (plz-see-insert-headers)))
                                   (current-buffer))))))

;;; Response buffer construction

(defun plz-see--prepare-buffer (response)
  "Create a prettified buffer from the RESPONSE contents."
  (let* ((buffer (generate-new-buffer
                  (format "*plz-see-%s*" (cl-incf (car plz-see--buffers)))))
         (error (and (plz-error-p response) response))
         (response (if error (plz-error-response error) response))
         (headers (plz-response-headers response))
         (mode (when-let ((ct (alist-get 'content-type headers)))
                 (alist-get ct plz-see-content-type-alist
                            nil nil #'string-match-p)))
         (body (plz-response-body response)))
    (with-current-buffer buffer
      (save-excursion
        (insert body)
        (when mode (funcall mode)))
      (setq-local plz-see-response response)
      (setq header-line-format plz-see-header-line-format)
      (push buffer (cdr plz-see--buffers))
      (when-let ((oldbufs (and plz-see-keep-buffers
                               (seq-drop (cdr plz-see--buffers)
                                         (1- plz-see-keep-buffers)))))
        (dolist (b (cdr oldbufs))
          (kill-buffer b))
        (setf (cdr oldbufs) nil))
      buffer)))

(defun plz-see--continue (as continue)
  "Continuation function for `plz' call made by `plz-see'.
CONTINUE is either the THEN or ELSE function of the `plz-see'
call and AS specifies the argument type they expect."
  (lambda (response)
    (if-let ((curl-error (and (plz-error-p response)
                              (plz-error-curl-error response))))
        (message "curl error %s: %s" (car curl-error) (cdr curl-error))
      (let ((buffer (plz-see--prepare-buffer response)))
        (display-buffer buffer plz-see-display-action)
        (when continue
          (funcall continue
                   (pcase-exhaustive as
                     ('response response)
                     ('buffer buffer)
                     ((or 'binary 'string 'file `(file ,_))
                      (user-error "plz-see does not accept :as %s" as))
                     ((pred functionp)
                      (with-temp-buffer
                        (insert (plz-response-body response))
                        (goto-char (point-min))
                        (funcall as))))))))))

;;; User commands

(defun plz-see-kill-old-buffers (n)
  "Kill all but the N most recent `plz-see' buffers.
Interactively, N is the prefix argument."
  (interactive "p")
  (let ((buffers (seq-drop plz-see--buffers n)))
    (dolist (buffer (cdr buffers))
      (kill-buffer buffer))
    (setf (cdr buffers) nil)))

(defun plz-see-insert-headers ()
  "Insert response headers into `plz-see-headers-buffer'."
  (interactive)
  (let ((headers (plz-response-headers plz-see-response))
        (hbuffer (when plz-see-headers-buffer
                   (get-buffer-create plz-see-headers-buffer))))
    (with-current-buffer (or hbuffer (current-buffer))
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (pcase-dolist (`(,k . ,v) headers)
            (insert (format "%s: %s\n" k v)))
          (insert ?\n)
          (add-text-properties (point-min) (point)
                               '(face plz-see-header
                                 font-lock-face plz-see-header
                                 fontified t)))))
    (if hbuffer
        (display-buffer hbuffer)
      (setq-local plz-see-header-line-show-headers nil))))

;;;###autoload
(cl-defun plz-see (method
                   url
                   &rest rest
                   &key headers then else as
                   &allow-other-keys)
  "Request METHOD from URL with curl and display the result in a buffer.

HEADERS may be an alist of extra headers to send with the
request.

BODY may be a string, a buffer, or a list like `(file FILENAME)'
to upload a file from disk.

AS selects the kind of result to pass to the callback function
THEN, or the kind of result to return for synchronous requests.
It may be (note that not all choices provided by the original
`plz' function are supported):

- `buffer' to pass the response buffer (after prettifying it with
  one of the `'plz-see-content-type-alist' entries).

- `response' to pass a `plz-response' structure.

- A function, which is called in the response buffer with it
  narrowed to the response body (suitable for, e.g. `json-read').

THEN is a callback function, whose sole argument is selected
above with AS; if the request fails and no ELSE function is
given (see below), the argument will be a `plz-error' structure
describing the error.  (Note that unlike the original `plz',
synchronous requests are not supported.)

ELSE is an optional callback function called when the request
fails (i.e. if curl fails, or if the HTTP response has a non-2xx
status code).  It is called with one argument, a `plz-error'
structure.

Other possible keyword arguments are BODY-TYPE, DECODE, FINALLY,
CONNECT-TIMEOUT, TIMEOUT and NOQUERY.  They are passed directly
to `plz', which see.

\(To silence checkdoc, we mention the internal argument REST.)"
  (interactive `(get ,(read-from-minibuffer "Make GET request: ")))
  (when (and plz-see-base-url
             (string-prefix-p "/" url))
    (setq url (concat plz-see-base-url url)))
  (dolist (h plz-see-base-headers)
    (unless (assoc (car h) headers)
      (push h headers)))
  (apply #'plz method url
         :headers headers
         :as 'response
         :then (plz-see--continue as then)
         :else (plz-see--continue as (or else then))
         rest))

(provide 'plz-see)
;;; plz-see.el ends here
