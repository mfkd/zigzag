# zigzag

zigzag creates a [GPX](https://en.wikipedia.org/wiki/GPS_Exchange_Format) file from a Komoot tour.

Zig version of [komootgpx](https://github.com/mfkd/komootgpx).

## Installation

Ensure you have Zig installed, then build:

```sh
zig build --release=fast
```

## Usage

Create a GPX file from a Komoot tour link:

```sh
zigzag -o file.gpx -u https://www.komoot.com/smarttour/23285
```
