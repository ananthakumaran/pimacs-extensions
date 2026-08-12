;;; pimacs-extensions.el --- Integrations for Pi extensions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Anantha Kumaran.

;; Author: Anantha kumaran <ananthakumaran@gmail.com>
;; URL: https://github.com/ananthakumaran/pimacs-extensions
;; Version: 0.1.0-pre
;; Keywords: convenience processes
;; Package-Requires: ((emacs "29.1") (pimacs "0.3.0"))

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

;; Optional Pimacs integrations for extensions to Pi Coding Agent.  Pass the
;; npm package names in use to `pimacs-enable-extensions'.

;;; Code:

(require 'pimacs)

(defgroup pimacs-extensions nil
  "Pimacs integrations for Pi extensions."
  :prefix "pimacs-"
  :group 'pimacs)

(defconst pimacs-extensions--registry
  '(("pi-hashline-edit" pimacs-hashline pimacs-hashline-enable))
  "Registry of npm package names, features, and setup functions.")

(defun pimacs-enable-extensions (&rest packages)
  "Enable Pimacs integrations for Pi extension npm PACKAGES."
  (dolist (package packages)
    (let ((entry (assoc package pimacs-extensions--registry)))
      (unless entry
        (error "Unsupported Pi extension package: %s" package))
      (require (nth 1 entry))
      (funcall (nth 2 entry)))))

(provide 'pimacs-extensions)

;;; pimacs-extensions.el ends here
