# pimacs-extensions

Pimacs integrations for Pi extensions.

## Supported packages

- [pi-hashline-edit-pro](https://github.com/YuGiMob/pi-hashline-edit-pro)

## Installation

Install the Pi extension:

```sh
pi install git:github.com/YuGiMob/pi-hashline-edit-pro
```

Install and enable its Pimacs integration from this repository:

```elisp
(use-package pimacs-extensions
  :vc (:url "https://github.com/ananthakumaran/pimacs-extensions.git"
       :rev :newest)
  :config
  (pimacs-enable-extensions
   "pi-hashline-edit-pro"))
```
