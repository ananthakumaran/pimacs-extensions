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

;; Displays the hashline read, write, grep, and edit tools in Pimacs.
;; Hash anchors remain visible to the model but are hidden in Emacs results.
;; All six edit tools support diff display, patch copying, and navigation;
;; copy/move results retain the file identity of each patch.  Applied edit
;; warnings and fidelity hints remain visible.
;;
;; Enabled by `(pimacs-enable-extensions "pi-hashline-edit-pro")'.

;;; Code:

(require 'pimacs-extensions)

(defconst pimacs-hashline--prefix-regexp
  "^[ \t]*[A-Za-z0-9]\\{4\\}│"
  "Regexp matching a pi-hashline-edit-pro line prefix.")

(defconst pimacs-hashline--diff-prefix-regexp
  "^\\([ +]\\)[ \t]*[A-Za-z0-9]\\{4\\}│"
  "Regexp matching a context or addition prefix in a hashline diff.")

(defconst pimacs-hashline--diff-deletion-prefix-regexp
  "^-[ \t]*\\(?:[A-Za-z0-9]\\{4\\}\\|    \\)│"
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

(defun pimacs-hashline--copy-replace-result (details _args)
  "Copy the standard patch in DETAILS, or an unanchored fallback diff."
  (when (eq (plist-get details :patchTruncated) t)
    (user-error "Patch is truncated; read the full files before applying it"))
  (let ((patch (plist-get details :patch)))
    (if (and patch (not (string-empty-p patch)))
        patch
      (when-let ((diff (plist-get details :diff)))
        (pimacs-hashline--normalize-diff diff)))))

(defun pimacs-hashline--insert-read-result (inserter content details args)
  "Normalize hashline read CONTENT and delegate to INSERTER."
  (funcall inserter
           (pimacs-hashline--strip-content-prefixes content)
           details args))
(defconst pimacs-hashline--grep-anchor-regexp
  "\\(^[ \t]*[0-9]+[ \t]*│[ \t]*\\)[A-Za-z0-9]\\{4\\}│"
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

(defun pimacs-hashline--edit-content (content details)
  "Keep notices from CONTENT and DETAILS without repeating an applied diff."
  (if (and (equal (plist-get (plist-get details :metrics) :classification)
                  "applied")
           (not (string-empty-p (or (plist-get details :patch)
                                    (plist-get details :diff) ""))))
      (let ((notices
             (delq nil
                   (mapcar
                    (lambda (entry)
                      (when-let ((items (plist-get details (car entry))))
                        (concat (cdr entry) ":\n"
                                (mapconcat #'identity items "\n"))))
                    '((:warnings . "Warnings") (:hints . "Hints"))))))
        (when notices
          (list (list :type "text" :text (string-join notices "\n\n")))))
    content))

(defun pimacs-hashline--insert-replace-result (inserter content details args)
  "Normalize hashline edit DETAILS and delegate to INSERTER."
  (let ((details (copy-sequence details)))
    (when (equal (plist-get details :patch) "")
      (setq details (plist-put details :patch nil)))
    (when-let ((diff (plist-get details :diff)))
      (setq details (plist-put details :diff
                               (pimacs-hashline--normalize-diff diff))))
    (funcall inserter (pimacs-hashline--edit-content content details)
             details args)))

(defun pimacs-hashline--patch-files (patch)
  "Split unified PATCH into (FILE . PATCH) entries.
Hashline uses the same literal path in both file headers, without a/b prefixes."
  (with-temp-buffer
    (insert patch)
    (goto-char (point-min))
    (let ((old-lines 0) (new-lines 0) headers files)
      (while (not (eobp))
        (cond
         ((or (> old-lines 0) (> new-lines 0))
          ;; Hunk content can itself resemble a pair of file headers.
          (pcase (char-after)
            (?\s (setq old-lines (1- old-lines) new-lines (1- new-lines)))
            (?- (setq old-lines (1- old-lines)))
            (?+ (setq new-lines (1- new-lines)))
            (?\\ nil)
            (_ (setq old-lines 0 new-lines 0))))
         ((looking-at "^@@ -[0-9]+\\(?:,\\([0-9]+\\)\\)? \\+[0-9]+\\(?:,\\([0-9]+\\)\\)? @@")
          (setq old-lines (if (match-string 1) (string-to-number (match-string 1)) 1)
                new-lines (if (match-string 2) (string-to-number (match-string 2)) 1)))
         ((looking-at "^--- [^\n]*\n\\+\\+\\+ \\([^\t\n]+\\)")
          (push (cons (point) (match-string 1)) headers)
          (forward-line)))
        (forward-line))
      (setq headers (nreverse headers))
      (while headers
        (let* ((header (pop headers))
               (end (if headers (caar headers) (point-max))))
          (push (cons (cdr header)
                      (buffer-substring-no-properties (car header) end))
                files)))
      (nreverse files))))

(defun pimacs-hashline--insert-transfer-result (inserter content details args)
  "Render CONTENT and DETAILS for copy/move, retaining each patch's file."
  (if-let ((files (pimacs-hashline--patch-files
                   (or (plist-get details :patch) ""))))
      (progn
        (dolist (file files)
          (let ((begin (point)))
            (pimacs--insert-file-link (car file) (pimacs--project-root))
            (insert "\n" (pimacs--render-diff (cdr file)))
            (add-text-properties begin (point)
                                 (list 'pimacs-hashline-file (car file)
                                       'rear-nonsticky t))))
        (let ((text (pimacs--content-text
                     (pimacs-hashline--edit-content content details))))
          (unless (string-empty-p text)
            (insert "\n\n" text))))
    ;; A guarded/empty patch still leaves useful feedback and an anchored diff.
    (pimacs-hashline--insert-replace-result inserter content details args)))

(defun pimacs-hashline--visit-transfer-result (_details _args)
  "Visit the file represented by the copy/move patch row at point.
Do not use the call's path hint: it can name the unmodified source of a copy."
  (when-let ((file (get-text-property (point) 'pimacs-hashline-file)))
    (let ((begin (if (equal file (get-text-property
                                  (max (point-min) (1- (point)))
                                  'pimacs-hashline-file))
                     (or (previous-single-property-change
                          (point) 'pimacs-hashline-file) (point-min))
                   (point)))
          (end (or (next-single-property-change
                    (point) 'pimacs-hashline-file) (point-max)))
          location)
      (save-restriction
        (narrow-to-region begin end)
        (setq location (pimacs--diff-hunk-location)))
      (list :file (expand-file-name file (pimacs--project-root))
            :line (max 1 (or (plist-get location :line) 1))
            :column (plist-get location :column)))))

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
  (pimacs-hashline--alias-tool-function
   "anchor_grep" "grep"
   'pimacs-insert-tool-args-functions "argument inserter")
  (dolist (tool '("insert" "replace" "replace_within" "copy" "move"
                  "undo_last_change"))
    (let ((transfer (member tool '("copy" "move"))))
      (pimacs-hashline--wrap-result-inserter
       tool (if transfer #'pimacs-hashline--insert-transfer-result
              #'pimacs-hashline--insert-replace-result) "edit")
      (pimacs-hashline--set-tool-function
       tool 'pimacs-copy-tool-result-functions
       #'pimacs-hashline--copy-replace-result)
      (pimacs-hashline--alias-tool-function
       tool "edit" 'pimacs-insert-tool-args-functions "argument inserter")
      (pimacs-hashline--alias-tool-function
       tool "edit" 'pimacs-visit-tool-call-functions "call visitor")
      (if transfer
          (pimacs-hashline--set-tool-function
           tool 'pimacs-visit-tool-result-functions
           #'pimacs-hashline--visit-transfer-result)
        (pimacs-hashline--alias-tool-function
         tool "edit" 'pimacs-visit-tool-result-functions "result visitor")))))

(provide 'pimacs-hashline)

;;; pimacs-hashline.el ends here
