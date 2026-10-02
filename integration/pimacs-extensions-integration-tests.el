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
  (let (inserted)
    (pimacs-hashline--insert-read-result
     (lambda (content _details _args) (setq inserted content))
     '((:type "text" :text "aB3d│(defun pimacs--start-agent (key)"))
     nil nil)
    (should
     (equal inserted
            '((:type "text" :text "(defun pimacs--start-agent (key)"))))))

(ert-deftest pimacs-extensions-hashline-fontifies-grep-content-only ()
  (with-temp-buffer
    (insert "nearby beta\n")
    (pimacs-hashline--insert-grep-result
     '((:type "text" :text "=== beta.txt ===\n1 │ aB3d│beta\n2 │ Zy9q│context"))
     nil '(:pattern "beta"))
    (insert "\nnearby beta")
    (should (equal (buffer-string)
                   "nearby beta\n=== beta.txt ===\n1 │ beta\n2 │ context\nnearby beta"))
    (goto-char (point-min))
    (search-forward "nearby beta")
    (should-not (get-text-property (1- (point)) 'face))
    (search-forward "beta.txt")
    (should (eq (get-text-property (1- (point)) 'face)
                'compilation-info))
    (search-forward "\n1 │")
    (should (eq (get-text-property (1- (point)) 'face) 'shadow))
    (search-forward "beta")
    (should (eq (get-text-property (1- (point)) 'face)
                'pimacs-grep-match-face))
    (search-forward "\nnearby beta")
    (should-not (get-text-property (1- (point)) 'face))))

(ert-deftest pimacs-extensions-hashline-visits-grep-results ()
  (with-temp-buffer
    (insert "=== src/example.el ===\n12 │ body")
    (search-backward "body")
    (forward-char 2)
    (should (equal (pimacs-hashline--visit-grep-result nil nil)
                   '(:file "src/example.el" :line 12 :column 2)))))

(ert-deftest pimacs-extensions-hashline-hides-write-auto-read ()
  (let (inserted)
    (pimacs-hashline--insert-write-result
     (lambda (content _details _args) (setq inserted content))
     '((:type "text" :text "Successfully wrote 139 bytes")
       (:type "text" :text "\n\n--- Auto-read (hashline anchors) ---\n6D3a│# Test File 1\nAuNb│\nAGec│This is a second test markdown file.\nBHfd│\nVone│## Sample Content\nWpof│\niZ9g│- Item 1\nXjth│- Item 2\nqsJi│- Item 3\nrtKj│\no9hk│Additional content can be added below."))
     nil nil)
    (should
     (equal inserted
            '((:type "text" :text "Successfully wrote 139 bytes")
              (:type "text" :text ""))))))

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

(defvar pimacs-extensions--settle-time (if (getenv "CI") 1 0.1))
(defvar pimacs-extensions--poll-interval (if (getenv "CI") 0.5 0.05))

(defun pimacs-extensions--drain-process-output (&optional timeout)
  (let* ((timeout (or timeout 120))
         (start (current-time))
         (buffer (pimacs--current-chat)))
    (sleep-for pimacs-extensions--settle-time)
    (when buffer
      (with-current-buffer buffer
        (while (and pimacs--agent-state
                    (< (time-to-seconds
                        (time-subtract (current-time) start))
                       timeout))
          (accept-process-output nil pimacs-extensions--poll-interval))))
    (sleep-for pimacs-extensions--settle-time)))

(defun pimacs-extensions--send-prompt-and-wait (prompt)
  (pimacs-send-prompt prompt)
  (pimacs-extensions--drain-process-output))

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
    (let* ((project pimacs-extensions--project-directory)
           (agent-directory pimacs-extensions--project-agent-directory)
           (fixture
            (expand-file-name
             "fixture/src/index.ts"
             pimacs-extensions--integration-directory))
           (hashline
            (expand-file-name
             "fixture/node_modules/pi-hashline-edit-pro/index.ts"
             pimacs-extensions--integration-directory))
           (sample (expand-file-name "sample.txt" project))
           (original-sample
            (with-temp-buffer
              (insert-file-contents sample)
              (buffer-string)))
           (destination (expand-file-name "destination.md" project))
           (original-destination
            (with-temp-buffer
              (insert-file-contents destination)
              (buffer-string)))
           (sessions-directory (expand-file-name "sessions" agent-directory))
           (default-directory (file-name-as-directory project))
           (pimacs-process-environment
            (list (concat "PI_CODING_AGENT_DIR=" agent-directory)
                  (concat "FIXTURE_MODE="
                          (pimacs-extensions--fixture-mode))
                  (concat "XDG_CONFIG_HOME=" (expand-file-name ".config" agent-directory))
                  (concat "FIXTURE_SCENARIO=" ,scenario)))
           (pimacs-flags
            (list "--tools" "read,replace,replace_within,insert,copy,move,anchor_grep,write,undo_last_change"
                  "--extension" hashline
                  "--extension" fixture)))
      (when (file-exists-p sessions-directory)
        (delete-directory sessions-directory t))
      (pimacs-enable-extensions "pi-hashline-edit-pro")
      (pimacs-chat)
      (sleep-for 2)
      (unwind-protect
          (progn
            ,@body
            (pimacs-extensions--drain-process-output)
            (pimacs--with-chat-buffer
             (pimacs-extensions--check-tape
              ,scenario ".txt"
              (buffer-substring (point-min) (point-max)))))
        (ignore-errors (pimacs-quit-chat))
        (write-region original-sample nil sample nil 'silent)
        (write-region original-destination nil destination nil 'silent)
        (when (file-exists-p sessions-directory)
          (delete-directory sessions-directory t))))))

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
    "Read sample.txt. Use replace_within to change beta to BETA. Without reading again, use the fresh anchor from the edit diff with replace_within to change BETA to BETTER. Finish.")
   (should (equal (pimacs-extensions--file-text sample) "alpha\nBETTER\ngamma\n"))))

(ert-deftest pimacs-extensions-hashline-copy ()
  (pimacs-extensions--with-integration-project
   "hashline-copy"
   (pimacs-extensions--send-prompt-and-wait
    "Read sample.txt and destination.md. Use copy exactly once to copy the beta line from sample.txt after the top line in destination.md, with path sample.txt. Then without reading again, use replace_within to change only the newly copied beta line in destination.md to BETA, using its fresh anchor from the copy diff. Leave the pre-existing beta line alone. Finish.")
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
