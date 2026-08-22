;;; pimacs-hashline.el --- Pimacs integration for pi-hashline-edit-pro -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Anantha Kumaran.

;; Author: Anantha kumaran <ananthakumaran@gmail.com>
;; URL: https://github.com/ananthakumaran/pimacs-extensions

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Makes the read, write, and replace tools supplied by pi-hashline-edit-pro look like
;; their built-in Pimacs counterparts.  Hash anchors remain visible to the
;; model but are removed from read results displayed in Emacs.  Successful
;; replace and undo results display their diff without the model-facing
;; fresh-anchor block.
;;
;; Enabled by `(pimacs-enable-extensions "pi-hashline-edit-pro")'.

;;; Code:

(require 'pimacs-extensions)

(defconst pimacs-hashline--prefix-regexp
  "^[ \t]*[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]│"
  "Regexp matching a pi-hashline-edit-pro line prefix.")

(defconst pimacs-hashline--diff-prefix-regexp
  "^\\([ +]\\)[ \t]*[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]│"
  "Regexp matching a context or addition prefix in a hashline diff.")

(defconst pimacs-hashline--diff-deletion-prefix-regexp
  "^-[ \t]*[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]│"
  "Regexp matching a deletion prefix in a hashline diff.")

(defconst pimacs-hashline--auto-read-marker
  "\n\n--- Auto-read "
  "Marker for model-only auto-read output appended to write results.")

(defun pimacs-hashline--strip-prefixes (text)
  "Return TEXT without pi-hashline-edit-pro display prefixes."
  (replace-regexp-in-string pimacs-hashline--prefix-regexp "" text))

(defun pimacs-hashline--strip-content-prefixes (content)
  "Copy CONTENT and remove hashline prefixes from its text items."
  (mapcar (lambda (item)
            (if (equal (plist-get item :type) "text")
                (let ((copy (copy-sequence item)))
                  (plist-put copy :text
                             (pimacs-hashline--strip-prefixes
                              (or (plist-get item :text) ""))))
              item))
          content))

(defun pimacs-hashline--strip-auto-read-content (content)
  "Copy CONTENT and remove model-only auto-read text items."
  (mapcar (lambda (item)
            (if (equal (plist-get item :type) "text")
                (let* ((copy (copy-sequence item))
                       (text (or (plist-get item :text) ""))
                       (start (string-match pimacs-hashline--auto-read-marker text)))
                  (plist-put copy :text
                             (if start (substring text 0 start) text)))
              item))
          content))

(defun pimacs-hashline--normalize-diff (diff)
  "Return hashline DIFF with model-facing line anchors removed."
  (let ((diff (replace-regexp-in-string
               pimacs-hashline--diff-prefix-regexp "\\1" diff)))
    (replace-regexp-in-string
     pimacs-hashline--diff-deletion-prefix-regexp "-" diff)))

(defun pimacs-hashline--insert-read-result (inserter content details args)
  "Normalize hashline read CONTENT and delegate to INSERTER."
  (funcall inserter
           (pimacs-hashline--strip-content-prefixes content)
           details args))

(defun pimacs-hashline--insert-write-result (inserter content details args)
  "Hide auto-read output from WRITE results displayed in Pimacs."
  (funcall inserter
           (pimacs-hashline--strip-auto-read-content content)
           details args))

(defun pimacs-hashline--insert-replace-result (inserter content details args)
  "Normalize hashline replace DETAILS and delegate to INSERTER."
  (let ((details (copy-sequence details)))
    (when-let ((diff (plist-get details :diff)))
      (setq details (plist-put details :diff
                               (pimacs-hashline--normalize-diff diff))))
    (let ((metrics (plist-get details :metrics)))
      (funcall inserter
               (if (equal (plist-get metrics :classification) "applied")
                   nil
                 content)
               details args))))

(defun pimacs-hashline--wrap-result-inserter (tool wrapper &optional source-tool)
  "Install WRAPPER as the result inserter for TOOL.
Use SOURCE-TOOL's built-in Pimacs inserter as the delegate when supplied."
  (let* ((source-tool (or source-tool tool))
         (inserter (or (alist-get source-tool pimacs-insert-tool-result-functions
                                  nil nil #'equal)
                       (alist-get tool pimacs-insert-tool-result-functions
                                  nil nil #'equal))))
    (unless (functionp inserter)
      (error "Pimacs has no result inserter for %s" source-tool))
    (setf (alist-get tool pimacs-insert-tool-result-functions
                     nil nil #'equal)
          (lambda (content details args)
            (funcall wrapper inserter content details args)))))

(defun pimacs-hashline--alias-tool-args (tool source-tool)
  "Use SOURCE-TOOL's argument inserter for TOOL."
  (let ((inserter (alist-get source-tool pimacs-insert-tool-args-functions
                             nil nil #'equal)))
    (unless (functionp inserter)
      (error "Pimacs has no argument inserter for %s" source-tool))
    (setf (alist-get tool pimacs-insert-tool-args-functions
                     nil nil #'equal)
          inserter)))

(defun pimacs-hashline-enable ()
  "Install the pi-hashline-edit-pro result inserters."
  (pimacs-hashline--wrap-result-inserter
   "read" #'pimacs-hashline--insert-read-result)
  (pimacs-hashline--wrap-result-inserter
   "write" #'pimacs-hashline--insert-write-result)
  (pimacs-hashline--wrap-result-inserter
   "replace" #'pimacs-hashline--insert-replace-result "edit")
  (pimacs-hashline--wrap-result-inserter
   "undo_last_replace" #'pimacs-hashline--insert-replace-result "edit")
  (pimacs-hashline--alias-tool-args "replace" "edit")
  (pimacs-hashline--alias-tool-args "undo_last_replace" "edit"))

(provide 'pimacs-hashline)

;;; pimacs-hashline.el ends here
