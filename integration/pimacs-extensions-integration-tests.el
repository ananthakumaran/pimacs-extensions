;;; pimacs-extensions-integration-tests.el --- Pimacs extensions integration tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Anantha Kumaran.

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; End-to-end Pimacs scenarios backed by deterministic Proxay tapes.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'pimacs)
(require 'pimacs-extensions)
(require 'pimacs-hashline)

(defconst pimacs-extensions--integration-directory
  (file-name-directory
   (or (and load-file-name (file-truename load-file-name))
       (and buffer-file-name (file-truename buffer-file-name)))))

(defun pimacs-extensions--project (directory)
  "Recognize the integration project rooted at DIRECTORY."
  (when-let ((root (locate-dominating-file directory ".project")))
    (cons 'transient root)))

(add-hook 'project-find-functions #'pimacs-extensions--project)

(defconst pimacs-extensions--tape-directory
  (expand-file-name "fixture/tapes"
                    pimacs-extensions--integration-directory))

(defconst pimacs-extensions--project-directory
  (expand-file-name "project" pimacs-extensions--integration-directory))

(defconst pimacs-extensions--project-agent-directory
  (expand-file-name "agent" pimacs-extensions--project-directory))

(defun pimacs-extensions--fixture-mode ()
  (or (getenv "FIXTURE_MODE") "replay"))

(defun pimacs-extensions--normalize-buffer-text (text)
  (replace-regexp-in-string
   (regexp-quote pimacs-extensions--project-directory)
   "PROJECT_DIR" text))

(ert-deftest pimacs-extensions-hashline-strips-anchors ()
  :tags '(unit)
  (let (inserted)
    (pimacs-hashline--insert-read-result
     (lambda (content _details _args) (setq inserted content))
     '((:type "text" :text "testa│(defun pimacs--start-agent (key)"))
     nil nil)
    (should
     (equal inserted
            '((:type "text" :text "(defun pimacs--start-agent (key)"))))))

(ert-deftest pimacs-extensions-hashline-fontifies-grep-content-only ()
  :tags '(unit)
  (with-temp-buffer
    (insert "nearby beta\n")
    (pimacs-hashline--insert-grep-result
     '((:type "text" :text "=== beta.txt ===\n1:│ testa│beta\n2:│ testb│context"))
     nil '(:pattern "beta"))
    (insert "\nnearby beta")
    (should (equal (buffer-string)
                   "nearby beta\n=== beta.txt ===\n1:│ beta\n2:│ context\nnearby beta"))
    (goto-char (point-min))
    (search-forward "nearby beta")
    (should-not (get-text-property (1- (point)) 'face))
    (search-forward "beta.txt")
    (should (eq (get-text-property (1- (point)) 'face)
                'compilation-info))
    (search-forward "\n1:│")
    (should (eq (get-text-property (1- (point)) 'face) 'shadow))
    (search-forward "beta")
    (should (eq (get-text-property (1- (point)) 'face)
                'pimacs-grep-match-face))
    (search-forward "\nnearby beta")
    (should-not (get-text-property (1- (point)) 'face))))

(ert-deftest pimacs-extensions-hashline-visits-grep-results ()
  :tags '(unit)
  (with-temp-buffer
    (insert "=== src/example.el ===\n12:│ body")
    (search-backward "body")
    (forward-char 2)
    (should (equal (pimacs-hashline--visit-grep-result nil nil)
                   '(:file "src/example.el" :line 12 :column 2)))))

(ert-deftest pimacs-extensions-hashline-hides-write-auto-read ()
  :tags '(unit)
  (let (inserted)
    (pimacs-hashline--insert-write-result
     (lambda (content _details _args) (setq inserted content))
     '((:type "text" :text "Successfully wrote 139 bytes")
       (:type "text" :text "\n\n--- Auto-read (hashline anchors) ---\ntestc│# Test File 1\ntestd│\nteste│This is a second test markdown file.\ntestf│\ntestg│## Sample Content\ntesth│\ntesti│- Item 1\ntestj│- Item 2\ntestk│- Item 3\ntestl│\ntestm│Additional content can be added below."))
     nil nil)
    (should
     (equal inserted
            '((:type "text" :text "Successfully wrote 139 bytes")
              (:type "text" :text ""))))))

(ert-deftest pimacs-extensions-hashline-five-character-anchors ()
  :tags '(unit)
  (should (equal (pimacs-hashline--strip-prefixes
                  "dafox│alpha\nemnox│  beta\nhdtmx│")
                 "alpha\n  beta\n"))
  (should (equal (pimacs-hashline--normalize-diff
                  " dafox│alpha\n-emnox│old\n+qwerx│new\n-     │duplicate")
                 " alpha\n-old\n+new\n-duplicate"))
  (should (equal (pimacs-hashline--copy-replace-result
                  '(:diff "-emnox│old\n+qwerx│new") nil)
                 "-old\n+new")))

(ert-deftest pimacs-extensions-hashline-grep-match-and-context-gutters ()
  :tags '(unit)
  (with-temp-buffer
    (pimacs-hashline--insert-grep-result
     '((:type "text" :text "=== src/example.el ===\n11-│ dafox│context\n12:│ emnox│beta"))
     nil '(:pattern "beta"))
    (should (equal (buffer-string)
                   "=== src/example.el ===\n11-│ context\n12:│ beta"))
    (goto-char (point-min))
    (search-forward "beta")
    (should (eq (get-text-property (1- (point)) 'face)
                'pimacs-grep-match-face))
    (should (equal (pimacs-hashline--visit-grep-result nil nil)
                   '(:file "src/example.el" :line 12 :column 4)))
    (search-backward "context")
    (should (equal (pimacs-hashline--visit-grep-result nil nil)
                   '(:file "src/example.el" :line 11 :column 0)))))

(ert-deftest pimacs-extensions-hashline-registers-current-tool-names ()
  :tags '(unit)
  (let ((pimacs-insert-tool-result-functions
         (copy-tree pimacs-insert-tool-result-functions))
        (pimacs-insert-tool-args-functions
         (copy-tree pimacs-insert-tool-args-functions))
        (pimacs-visit-tool-result-functions
         (copy-tree pimacs-visit-tool-result-functions))
        (pimacs-visit-tool-call-functions
         (copy-tree pimacs-visit-tool-call-functions))
        (pimacs-copy-tool-result-functions
         (copy-tree pimacs-copy-tool-result-functions)))
    (pimacs-hashline-enable)
    (should (eq (alist-get "grep" pimacs-insert-tool-result-functions nil nil #'equal)
                #'pimacs-hashline--insert-grep-result))
    (should (eq (alist-get "grep" pimacs-visit-tool-result-functions nil nil #'equal)
                #'pimacs-hashline--visit-grep-result))
    (dolist (alist (list pimacs-insert-tool-result-functions
                         pimacs-insert-tool-args-functions
                         pimacs-visit-tool-call-functions
                         pimacs-visit-tool-result-functions
                         pimacs-copy-tool-result-functions))
      (should (functionp (alist-get "replace_match" alist nil nil #'equal))))))

(defun pimacs-extensions--check-tape (scenario suffix text)
  (let* ((tape-file
          (expand-file-name (concat scenario suffix)
                            pimacs-extensions--tape-directory))
         (current-text (pimacs-extensions--normalize-buffer-text text))
         (fixture-mode (pimacs-extensions--fixture-mode)))
    (if (or (not (file-exists-p tape-file))
            (string= fixture-mode "record"))
        (write-region current-text nil tape-file nil 'silent)
      (let ((expected
             (pimacs-extensions--normalize-buffer-text
              (with-temp-buffer
                (insert-file-contents tape-file)
                (buffer-string)))))
        (unless (string= current-text expected)
          (let ((temp-file (make-temp-file "pimacs-tape-")))
            (unwind-protect
                (progn
                  (write-region current-text nil temp-file nil 'silent)
                  (with-temp-buffer
                    (call-process "diff" nil (current-buffer) nil
                                  "-u" tape-file temp-file)
                    (message "Tape mismatch for %s:\n%s"
                             scenario (buffer-string))
                    (ert-fail (format "Tape mismatch for %s" scenario))))
              (delete-file temp-file))))))))

(defvar pimacs-extensions--timeout 10
  "Maximum seconds to wait for a replay prompt; recording allows 120 seconds.")

(defun pimacs-extensions--fail (reason)
  "Fail with REASON and the relevant process diagnostics."
  (let ((stderr (get-buffer "*pimacs-stderr*"))
        (chat (pimacs--current-chat)))
    (ert-fail
     (format "%s\nStderr:\n%s\nChat tail:\n%s"
             reason
             (if (buffer-live-p stderr)
                 (with-current-buffer stderr
                   (buffer-substring-no-properties
                    (max (point-min) (- (point-max) 2000)) (point-max)))
               "")
             (if (buffer-live-p chat)
                 (with-current-buffer chat
                   (buffer-substring-no-properties
                    (max (point-min) (- (point-max) 2000)) (point-max)))
               "")))))

(defun pimacs-extensions--wait-for-settled (action)
  "Run ACTION and wait for agent_settled, failing on errors or a short deadline."
  (let ((buffer (pimacs--current-chat))
        (deadline (+ (float-time)
                     (if (equal (pimacs-extensions--fixture-mode) "record")
                         120 pimacs-extensions--timeout)))
        settled failure last-event)
    (unless (buffer-live-p buffer)
      (pimacs-extensions--fail "Chat did not start"))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (pimacs--set-event-listener
             t 'pimacs-extensions-wait
             (lambda (event)
               (setq last-event (plist-get event :type))
               (cond
                ((equal last-event "agent_settled") (setq settled t))
                ((and (equal last-event "tool_execution_end")
                      (eq (plist-get event :isError) t))
                 (setq failure (format "Tool failed: %S" event)))
                ((equal last-event "extension_error")
                 (setq failure (format "Extension failed: %S" event)))
                ((and (equal last-event "message_end")
                      (member (plist-get (plist-get event :message) :stopReason)
                              '("error" "aborted")))
                 (setq failure (format "Provider failed: %S" (plist-get event :message))))))))
          (funcall action)
          (while (not (or settled failure))
            (unless (and (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (process-live-p (pimacs--current-agent))))
              (setq failure "Agent exited before settling"))
            (when (> (float-time) deadline)
              (setq failure (format "Timed out waiting for agent_settled (last event: %s)"
                                    last-event)))
            (unless failure (accept-process-output nil 0.01)))
          (when failure (pimacs-extensions--fail failure)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (pimacs--remove-event-listener t 'pimacs-extensions-wait))))))

(defun pimacs-extensions--send-prompt-and-wait (prompt)
  (pimacs-extensions--wait-for-settled (lambda () (pimacs-send-prompt prompt))))


(defconst pimacs-extensions--silenced-message-patterns
  '("^(.*) Starting pimacs version .+\\.\\.$"
    "^(.*) pimacs agent started successfully\\.$"
    "^(.*) pimacs exits: killed\\(: [0-9]+\\)?\\.$"))

(defmacro pimacs-extensions--with-silenced-messages (&rest body)
  (declare (indent 0))
  `(let ((message-fn (symbol-function 'message)))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest args)
                  (let ((text (apply #'format-message format-string args)))
                    (unless (cl-some
                             (lambda (pattern)
                               (string-match-p pattern text))
                             pimacs-extensions--silenced-message-patterns)
                      (funcall message-fn "%s" text))))))
       ,@body)))

(defmacro pimacs-extensions--with-integration-project (scenario &rest body)
  (declare (indent 1))
  `(pimacs-extensions--with-silenced-messages
    (let* ((project (make-temp-file "pimacs-extensions-" t))
           (pimacs-extensions--project-directory project)
           (agent-directory (expand-file-name "agent" project))
           (fixture (expand-file-name "fixture/src/index.ts"
                                      pimacs-extensions--integration-directory))
           (hashline (expand-file-name
                      "fixture/node_modules/pi-hashline-edit-pro/index.ts"
                      pimacs-extensions--integration-directory))
           (sample (expand-file-name "sample.txt" project))
           (original-sample "alpha\nbeta\ngamma\n")
           (destination (expand-file-name "destination.md" project))
           (original-destination "top\nbeta\n")
           (default-directory (file-name-as-directory project))
           (pimacs-process-environment
            (list (concat "PI_CODING_AGENT_DIR=" agent-directory)
                  (concat "FIXTURE_MODE=" (pimacs-extensions--fixture-mode))
                  (concat "XDG_CONFIG_HOME=" (expand-file-name ".config" agent-directory))
                  (concat "FIXTURE_SCENARIO=" ,scenario)))
           (pimacs-executable
            (expand-file-name "fixture/node_modules/.bin/pi"
                              pimacs-extensions--integration-directory))
           (pimacs-sync-request-timeout pimacs-extensions--timeout)
           (pimacs-flags
            (list "--tools" "read,replace,replace_match,insert,copy,move,grep,write,undo_last_change"
                  "--extension" hashline "--extension" fixture)))
      (unwind-protect
          (progn
            (make-directory (expand-file-name ".config/pi-hashline-edit-pro" agent-directory) t)
            (dolist (file '("settings.json" "auth.json" ".config/pi-hashline-edit-pro/config.json"))
              (copy-file (expand-file-name file pimacs-extensions--project-agent-directory)
                         (expand-file-name file agent-directory)))
            (write-region "" nil (expand-file-name ".project" project) nil 'silent)
            (write-region original-sample nil sample nil 'silent)
            (write-region original-destination nil destination nil 'silent)
            (pimacs-enable-extensions "pi-hashline-edit-pro")
            (pimacs-chat)
            ;; The RPC round trip waits for extension/provider startup, not a fixed sleep.
            (pimacs--with-chat-buffer
             (should (pimacs--response-success-p
                      (pimacs--send-command-sync "get_state" '()))))
            ,@body
            (pimacs--with-chat-buffer
             (pimacs-extensions--check-tape
              ,scenario ".txt"
              (buffer-substring (point-min) (point-max)))))
        (ignore-errors (pimacs-quit-chat))
        (delete-directory project t)))))

(ert-deftest pimacs-extensions-hashline-replace ()
  (pimacs-extensions--with-integration-project
   "hashline"
   (pimacs-extensions--send-prompt-and-wait
    "Read sample.txt, replace beta with BETA using replace, then finish.")))

(ert-deftest pimacs-extensions-hashline-insert ()
  (pimacs-extensions--with-integration-project
   "hashline-insert"
   (pimacs-extensions--send-prompt-and-wait
    "Read sample.txt, insert a new line `delta` after the line `beta` using insert tool.")))

(ert-deftest pimacs-extensions-hashline-grep ()
  (pimacs-extensions--with-integration-project
   "hashline-grep"
   (pimacs-extensions--send-prompt-and-wait
    "Use grep tool and search for `beta` in *.txt")))

(ert-deftest pimacs-extensions-hashline-undo-last-change ()
  (pimacs-extensions--with-integration-project
   "hashline-undo"
   (pimacs-extensions--send-prompt-and-wait
    "Read sample.txt, replace beta with BETA using replace, then undo it with undo_last_change, then finish.")))

(ert-deftest pimacs-extensions-hashline-write ()
  (pimacs-extensions--with-integration-project
   "hashline-write"
   (pimacs-extensions--send-prompt-and-wait
    "Use the write tool exactly once to create /tmp/test1.md with this exact content, then finish without using any other tool:\n# Test File 1\n\nThis is a second test markdown file.\n\n## Sample Content\n\n- Item 1\n- Item 2\n- Item 3\n\nAdditional content can be added below.")))

(defun pimacs-extensions--file-text (file)
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(ert-deftest pimacs-extensions-hashline-replace-within ()
  (pimacs-extensions--with-integration-project
   "hashline-replace-within"
   (pimacs-extensions--send-prompt-and-wait
    "Read sample.txt. Use replace_match to change beta to BETA. Without reading again, use the fresh anchor from the edit diff with replace_match to change BETA to BETTER. Finish.")
   (should (equal (pimacs-extensions--file-text sample) "alpha\nBETTER\ngamma\n"))))

(ert-deftest pimacs-extensions-hashline-copy ()
  (pimacs-extensions--with-integration-project
   "hashline-copy"
   (pimacs-extensions--send-prompt-and-wait
    "Read sample.txt and destination.md. Use copy exactly once to copy the beta line from sample.txt after the top line in destination.md, with path sample.txt. Then without reading again, use replace_match to change only the newly copied beta line in destination.md to BETA, using its fresh anchor from the copy diff. Leave the pre-existing beta line alone. Finish.")
   (should (equal (pimacs-extensions--file-text sample) original-sample))
   (should (equal (pimacs-extensions--file-text destination) "top\nBETA\nbeta\n"))))

(ert-deftest pimacs-extensions-hashline-move ()
  (pimacs-extensions--with-integration-project
   "hashline-move"
   (pimacs-extensions--send-prompt-and-wait
    "Read sample.txt and destination.md. Use move exactly once to move the beta line from sample.txt after the top line in destination.md, with path sample.txt. Finish without undoing or reading again.")
   (should (equal (pimacs-extensions--file-text sample) "alpha\ngamma\n"))
   (should (equal (pimacs-extensions--file-text destination) "top\nbeta\nbeta\n"))
   (pimacs-extensions--send-prompt-and-wait
    "Now undo the cross-file move completely with undo_last_change on both sample.txt and destination.md, then finish.")
   (should (equal (pimacs-extensions--file-text sample) original-sample))
   (should (equal (pimacs-extensions--file-text destination) original-destination))))

;;; pimacs-extensions-integration-tests.el ends here
