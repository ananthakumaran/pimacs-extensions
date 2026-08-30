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

;; Makes the read, write, insert, and replace tools supplied by pi-hashline-edit-pro
;; look like their built-in Pimacs counterparts.  Hash anchors remain visible to
;; the model but are removed from read and insert results displayed in Emacs.
;; Successful insert, replace, and undo results display their diff without the model-facing
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
(defconst pimacs-hashline--grep-anchor-regexp
  "\\(^[ \\t]*[0-9]+[ \\t]*│[ \\t]*\\)[A-Za-z0-9]\\{3\\}│"
  "Regexp matching the anchor in a numbered hashline grep row.")

(defconst pimacs-hashline--grep-row-regexp
  "^[ \\t]*\\([0-9]+\\)[ \\t]*\\(│\\)[ \\t]*\\(.*\\)$"
  "Regexp matching a displayed hashline grep row after anchor removal.")

(defconst pimacs-hashline--grep-header-regexp
  "^=== \\(.*\\) ===$"
  "Regexp matching a hashline grep file header.")

(defun pimacs-hashline--fontify-grep-rows (begin end regexp ignore-case)
  "Fontify hashline grep rows between BEGIN and END."
  (save-excursion
    (save-restriction
      (narrow-to-region begin end)
      (goto-char (point-min))
      (while (not (eobp))
        (cond
         ((looking-at pimacs-hashline--grep-header-regexp)
          (add-text-properties (match-beginning 1) (match-end 1)
                               '(face compilation-info)))
         ((looking-at pimacs-hashline--grep-row-regexp)
          (add-text-properties (match-beginning 1) (match-end 1)
                               '(face compilation-line-number))
          (add-text-properties (match-beginning 2) (match-end 2)
                               '(face shadow))
          (pimacs--fontify-grep-matches
           (match-beginning 3) (match-end 3) regexp ignore-case)))
        (forward-line 1)))))


(defun pimacs-hashline--visit-grep-result (_details args)
  "Return the file position represented by the hashline grep row at point."
  (let ((cursor-position (point))
        (section (pimacs-section--current-section)))
    (save-excursion
      (beginning-of-line)
      (when (looking-at pimacs-hashline--grep-row-regexp)
        (let ((line (string-to-number (match-string 1)))
              (content-begin (match-beginning 3))
              (content-end (match-end 3)))
          (when (re-search-backward
                 pimacs-hashline--grep-header-regexp
                 (if section (pimacs-section-beginning section) (point-min))
                 t)
            (list :file (pimacs--normalize-grep-file (match-string 1) args)
                  :line line
                  :column (max 0 (min (- cursor-position content-begin)
                                      (- content-end content-begin))))))))))
(defun pimacs-hashline--insert-grep-result (content _details args)
  "Insert hashline grep CONTENT and fontify matches in grep rows only."
  (let* ((pattern (plist-get args :pattern))
         (literal (eq (plist-get args :literal) t))
         (ignore-case (eq (plist-get args :ignoreCase) t))
         (fontify (and pattern (not (string-empty-p pattern))))
         (regexp (and fontify (pimacs--grep-pattern-regexp pattern literal)))
         (result-text
          (replace-regexp-in-string
           pimacs-hashline--grep-anchor-regexp "\\1"
           (pimacs--content-text content)))
         (begin (point)))
    (insert result-text)
    (when fontify
      (pimacs-hashline--fontify-grep-rows begin (point) regexp ignore-case))))

(defun pimacs-hashline--insert-write-result (inserter content details args)
  "Hide auto-read output from WRITE results displayed in Pimacs."
  (funcall inserter
           (pimacs-hashline--strip-auto-read-content content)
           details args))

(defun pimacs-hashline--insert-replace-result (inserter content details args)
  "Normalize hashline edit DETAILS and delegate to INSERTER."
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

(defun pimacs-hashline--tool-function (tool function-alist)
  (alist-get tool (symbol-value function-alist) nil nil #'equal))

(defun pimacs-hashline--set-tool-function (tool function-alist function)
  (let ((alist (symbol-value function-alist)))
    (setf (alist-get tool alist nil nil #'equal) function)
    (set function-alist alist)
    function))

(defun pimacs-hashline--alias-tool-function
    (tool source-tool function-alist description)
  (let ((function (pimacs-hashline--tool-function source-tool function-alist)))
    (unless (functionp function)
      (error "Pimacs has no %s for %s" description source-tool))
    (pimacs-hashline--set-tool-function tool function-alist function)))

(defun pimacs-hashline--wrap-result-inserter (tool wrapper &optional source-tool)
  "Install WRAPPER as the result inserter for TOOL.
Use SOURCE-TOOL's built-in Pimacs inserter as the delegate when supplied."
  (let* ((source-tool (or source-tool tool))
         (inserter (or (pimacs-hashline--tool-function
                        source-tool
                        'pimacs-insert-tool-result-functions)
                       (pimacs-hashline--tool-function
                        tool
                        'pimacs-insert-tool-result-functions))))
    (unless (functionp inserter)
      (error "Pimacs has no result inserter for %s" source-tool))
    (pimacs-hashline--set-tool-function
     tool
     'pimacs-insert-tool-result-functions
     (lambda (content details args)
       (funcall wrapper inserter content details args)))))

(defun pimacs-hashline-enable ()
  "Install the pi-hashline-edit-pro result inserters."
  (pimacs-hashline--wrap-result-inserter
   "read" #'pimacs-hashline--insert-read-result)
  (pimacs-hashline--set-tool-function
   "anchor_grep"
   'pimacs-insert-tool-result-functions
   #'pimacs-hashline--insert-grep-result)
  (pimacs-hashline--set-tool-function
   "anchor_grep"
   'pimacs-visit-tool-result-functions
   #'pimacs-hashline--visit-grep-result)
  (pimacs-hashline--wrap-result-inserter
   "write" #'pimacs-hashline--insert-write-result)
  (pimacs-hashline--wrap-result-inserter
   "insert" #'pimacs-hashline--insert-replace-result "edit")
  (pimacs-hashline--wrap-result-inserter
   "replace" #'pimacs-hashline--insert-replace-result "edit")
  (pimacs-hashline--wrap-result-inserter
   "undo_last_change" #'pimacs-hashline--insert-replace-result "edit")
  (pimacs-hashline--alias-tool-function
   "anchor_grep" "grep"
   'pimacs-insert-tool-args-functions "argument inserter")
  (pimacs-hashline--alias-tool-function
   "insert" "edit"
   'pimacs-insert-tool-args-functions "argument inserter")
  (pimacs-hashline--alias-tool-function
   "replace" "edit"
   'pimacs-insert-tool-args-functions "argument inserter")
  (pimacs-hashline--alias-tool-function
   "undo_last_change" "edit"
   'pimacs-insert-tool-args-functions "argument inserter")
  (pimacs-hashline--alias-tool-function
   "insert" "edit"
   'pimacs-visit-tool-result-functions "result visitor")
  (pimacs-hashline--alias-tool-function
   "replace" "edit"
   'pimacs-visit-tool-result-functions "result visitor")
  (pimacs-hashline--alias-tool-function
   "undo_last_change" "edit"
   'pimacs-visit-tool-result-functions "result visitor")
  (pimacs-hashline--alias-tool-function
   "insert" "edit"
   'pimacs-visit-tool-call-functions "call visitor")
  (pimacs-hashline--alias-tool-function
   "replace" "edit"
   'pimacs-visit-tool-call-functions "call visitor")
  (pimacs-hashline--alias-tool-function
   "undo_last_change" "edit"
   'pimacs-visit-tool-call-functions "call visitor"))

(provide 'pimacs-hashline)

;;; pimacs-hashline.el ends here
