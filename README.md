## apns-http2

`apns-http2` is a library which uses the building blocks from the [`http2`](https://github.com/kazu-yamamoto/http2) package to implement a client library for sending push notifications to [APNs](https://developer.apple.com/notifications/) (Apple Push Notification service) via its newer HTTP/2 based protocol. It does not (presently) handle formatting of the push content or connection management, but handles all the intricacies of a single connection which is essentially an HTTP/2 client with a few specializations made since one doesn't already seem to exist for Haskell.

## Example

Located in `example/Main.hs`.

## Maturity

As of writing, the library has gone through some low-load development tests but has not yet gone into production. We'd appreciate any fixes, improvements, or experience reports.

## Contributing

Contributions and feedback welcome! File an issue or make a PR.

## Chat

Asa (@asa) and Ross (@dridus) lurk on [fpchat](https://fpchat.com). You can also reach us at `oss@confer.health`.


