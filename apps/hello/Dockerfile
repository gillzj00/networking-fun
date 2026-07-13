FROM golang:1.22-alpine AS build
ARG VERSION=dev
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -ldflags "-X main.version=${VERSION}" -o /hello .

FROM scratch
COPY --from=build /hello /hello
USER 65534:65534
EXPOSE 8080
ENTRYPOINT ["/hello"]
