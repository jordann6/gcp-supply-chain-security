# Two stages, and the second one has no package manager, no shell, and no libc.
#
# That is not minimalism for its own sake. The vulnerability gate downstream
# scans whatever this produces, and the overwhelming majority of findings in a
# typical container are in distro packages the application never calls. Shipping
# a static binary on a distroless base means the scan result is about the code
# rather than about Debian's release cadence, and a gate whose output is mostly
# irrelevant is a gate that gets turned off.

FROM golang:1.25-bookworm AS build

WORKDIR /src

# No third-party dependencies, so there is no module download step and nothing
# to cache. If that changes, copy go.mod and go.sum first and run go mod
# download as its own layer.
COPY go.mod ./
COPY main.go ./

# CGO off produces a genuinely static binary, which is what lets the runtime
# stage have no libc at all. Trimpath keeps build machine paths out of the
# binary, and -s -w drop the symbol and DWARF tables.
ENV CGO_ENABLED=0 GOOS=linux
RUN go build -trimpath -ldflags="-s -w" -o /out/server .

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/server /server

# Numeric rather than the nonroot alias. Kubernetes runAsNonRoot cannot verify a
# username, only a UID, so a named user reads as unverifiable there. Cloud Run
# does not care, but the image should be correct in both places.
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/server"]
