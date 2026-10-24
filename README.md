# pimacs-extensions

Pimacs integrations for Pi extensions.

## Supported packages

- [pi-hashline-edit-pro](https://github.com/YuGiMob/pi-hashline-edit-pro)

## Installation

Install the Pi extension:

```sh
pi install npm:pi-hashline-edit-pro
```

For `pi-hashline-edit-pro` 7.x, use Pi 0.99.0+ and Node.js 22.19+.
In Pi, open `/hashline-config` and enable **Require path** so edit calls
include the file path used by Pimacs for display and navigation.

Install and enable its Pimacs integration from this repository:

```elisp
(use-package pimacs-extensions
  :vc (:url "https://github.com/ananthakumaran/pimacs-extensions.git"
       :rev :newest)
  :config
  (pimacs-enable-extensions
   "pi-hashline-edit-pro"))
```
