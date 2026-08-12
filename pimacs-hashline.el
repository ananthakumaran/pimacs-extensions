;;; pimacs-hashline.el --- Pimacs integration for pi-hashline-edit -*- lexical-binding: t; -*-

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

;; Makes the read and edit tools supplied by pi-hashline-edit look like their
;; built-in Pimacs counterparts.  Hash anchors remain visible to the model but
;; are removed from read results displayed in Emacs.  Successful edit results
;; display their diff without the model-facing fresh-anchor block.
;;
;; Enabled by `(pimacs-enable-extensions "pi-hashline-edit")'.

;;; Code:

(require 'pimacs-extensions)

(defconst pimacs-hashline--prefix-regexp
  "^[ \t]*[0-9]+#[ZPMQVRWSNKTXJBYH]\\{2,4\\}:"
  "Regexp matching a pi-hashline-edit line prefix.")

(defconst pimacs-hashline--diff-prefix-regexp
  "^\\([ +]\\)[ \t]*[0-9]+#[ZPMQVRWSNKTXJBYH]\\{2,4\\}:"
  "Regexp matching a context or addition prefix in a hashline diff.")

(defconst pimacs-hashline--diff-deletion-prefix-regexp
  "^-[ \t]*[0-9]+[ ]\\{4,6\\}"
  "Regexp matching a deletion prefix in a hashline diff.")

(defconst pimacs-hashline--grep-line-regexp
  "^[ \t]*\\([0-9]+\\)#[ZPMQVRWSNKTXJBYH]\\{2,4\\}:\\(.*\\)$"
  "Regexp matching a result line from hashline grep.")

(defun pimacs-hashline--strip-prefixes (text)
  "Return TEXT without pi-hashline-edit display prefixes."
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

(defun pimacs-hashline--normalize-diff (diff)
  "Return hashline DIFF with model-facing line anchors removed."
  (let ((diff (replace-regexp-in-string
               pimacs-hashline--diff-prefix-regexp "\\1" diff)))
    (replace-regexp-in-string
     pimacs-hashline--diff-deletion-prefix-regexp "-" diff)))

(defun pimacs-hashline--normalize-grep-text (text)
  "Convert hashline grep TEXT to Pimacs' normal file:line format."
  (let (file output)
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match "^\\(.+\\):$" line)
        (setq file (match-string 1 line)))
       ((and file
             (string-match pimacs-hashline--grep-line-regexp line))
        (push (format "%s:%s: %s"
                      file (match-string 1 line) (match-string 2 line))
              output))
       ((equal line "---")
        (setq file nil))
       (t
        (push line output))))
    (mapconcat #'identity (nreverse output) "\n")))

(defun pimacs-hashline--normalize-grep-content (content)
  "Copy hashline grep CONTENT and normalize its text items."
  (mapcar (lambda (item)
            (if (equal (plist-get item :type) "text")
                (let ((copy (copy-sequence item)))
                  (plist-put copy :text
                             (pimacs-hashline--normalize-grep-text
                              (or (plist-get item :text) ""))))
              item))
          content))

(defun pimacs-hashline--insert-read-result (inserter content details args)
  "Normalize hashline read CONTENT and delegate to INSERTER."
  (funcall inserter
           (if (plist-get args :raw)
               content
             (pimacs-hashline--strip-content-prefixes content))
           details args))

(defun pimacs-hashline--insert-edit-result (inserter content details args)
  "Normalize hashline edit DETAILS and delegate to INSERTER."
  (let ((details (copy-sequence details)))
    (when-let ((diff (plist-get details :diff)))
      (setq details (plist-put details :diff
                               (pimacs-hashline--normalize-diff diff))))
    (funcall inserter
             (if (equal (plist-get details :classification) "applied")
                 nil
               content)
             details args)))

(defun pimacs-hashline--insert-grep-result (inserter content details args)
  "Normalize hashline grep CONTENT and delegate to INSERTER."
  (funcall inserter
           (pimacs-hashline--normalize-grep-content content) details args))

(defun pimacs-hashline--wrap-result-inserter (tool wrapper)
  "Wrap the current result inserter for TOOL with WRAPPER."
  (let ((inserter (alist-get tool pimacs-insert-tool-result-functions
                             nil nil #'equal)))
    (unless (functionp inserter)
      (error "Pimacs has no result inserter for %s" tool))
    (setf (alist-get tool pimacs-insert-tool-result-functions
                     nil nil #'equal)
          (lambda (content details args)
            (funcall wrapper inserter content details args)))))

(defun pimacs-hashline-enable ()
  "Install the pi-hashline-edit result inserters."
  (pimacs-hashline--wrap-result-inserter
   "read" #'pimacs-hashline--insert-read-result)
  (pimacs-hashline--wrap-result-inserter
   "edit" #'pimacs-hashline--insert-edit-result)
  (pimacs-hashline--wrap-result-inserter
   "grep" #'pimacs-hashline--insert-grep-result))

(provide 'pimacs-hashline)

;;; pimacs-hashline.el ends here
