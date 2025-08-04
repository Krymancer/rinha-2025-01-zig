set shell := ["powershell.exe", "-c"]

default:
    @just run

run:
    docker compose down
    docker compose build
    docker volume rm rinha-2025-01-zig_rb2025
    docker compose up

clean:
    docker compose down
    docker volume rm rinha-2025-01-zig_rb2025

build:
    docker compose build
