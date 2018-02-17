[etc-websockets](https://tonyday567.github.io/etc-websockets/index.html) [![Build Status](https://travis-ci.org/tonyday567/etc-websockets.svg)](https://travis-ci.org/tonyday567/etc-websockets)
===

emit - transduce - commit

websockets

compilation recipe
---

```
stack build --test --fast --haddock --exec "$(stack path --local-install-root)/bin/wsdebug"
```

```
lsof -i tcp:3566
```
