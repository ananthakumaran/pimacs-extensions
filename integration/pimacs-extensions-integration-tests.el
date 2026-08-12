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
  '("^(.*) Starting pimacs version .+\\.\\.\\.$"
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
             "fixture/node_modules/pi-hashline-edit/index.ts"
             pimacs-extensions--integration-directory))
           (sample (expand-file-name "sample.txt" project))
           (original-sample
            (with-temp-buffer
              (insert-file-contents sample)
              (buffer-string)))
           (sessions-directory (expand-file-name "sessions" agent-directory))
           (default-directory (file-name-as-directory project))
           (pimacs-process-environment
            (list (concat "PI_CODING_AGENT_DIR=" agent-directory)
                  (concat "FIXTURE_MODE="
                          (pimacs-extensions--fixture-mode))
                  (concat "FIXTURE_SCENARIO=" ,scenario)))
           (pimacs-flags
            (list "--tools" "read,edit,write,grep"
                  "--extension" fixture
                  "--extension" hashline)))
      (when (file-exists-p sessions-directory)
        (delete-directory sessions-directory t))
      (pimacs-enable-extensions "pi-hashline-edit")
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
        (when (file-exists-p sessions-directory)
          (delete-directory sessions-directory t))))))

(ert-deftest pimacs-extensions-hashline ()
  (pimacs-extensions--with-integration-project
   "hashline"
   (pimacs-extensions--send-prompt-and-wait
    "Read sample.txt, replace beta with BETA using edit, then finish.")))

(ert-deftest pimacs-extensions-hashline-grep ()
  (pimacs-extensions--with-integration-project
   "hashline-grep"
   (pimacs-extensions--send-prompt-and-wait
    "Use the grep tool exactly once to find beta in sample.txt, then finish. Do not use any other tool.")))

;;; pimacs-extensions-integration-tests.el ends here
