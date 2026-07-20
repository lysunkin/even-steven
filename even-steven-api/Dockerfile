FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o /bin/api ./cmd/api

FROM alpine:3.20
RUN apk --no-cache add ca-certificates
COPY --from=builder /bin/api /bin/api
ENTRYPOINT ["/bin/api"]
