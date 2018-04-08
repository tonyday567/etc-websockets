[websocket-box](https://tonyday567.github.io/websocket-box/index.html) [![Build Status](https://travis-ci.org/tonyday567/websocket-box.svg)](https://travis-ci.org/tonyday567/websocket-box)
===

A concurrent, effectful websocket.  In a box.

compilation recipe
---

```
stack build --test --fast --haddock --exec "$(stack path --local-install-root)/bin/esocket"
```

```
lsof -i tcp:3566
```
