# pimacs-extensions

Pimacs integrations for Pi extensions.

## Supported packages

- [pi-hashline-edit](https://github.com/RimuruW/pi-hashline-edit)

## Installation

Install the Pi extension:

```sh
pi install npm:pi-hashline-edit
```

Install and enable its Pimacs integration from this repository:

```elisp
(use-package pimacs-extensions
  :vc (:url "https://github.com/ananthakumaran/pimacs-extensions.git"
       :rev :newest)
  :config
  (pimacs-enable-extensions
   "pi-hashline-edit"))
```
