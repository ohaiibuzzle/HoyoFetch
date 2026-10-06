#!/bin/sh
# Regenerates Sources/SophonKit/Proto/*.pb.swift from Protos/*.proto.
# Needs protoc and protoc-gen-swift
set -eu
cd "$(dirname "$0")/.."
protoc --proto_path=Protos --swift_opt=Visibility=Internal --swift_out=Sources/SophonKit/Proto Protos/*.proto
