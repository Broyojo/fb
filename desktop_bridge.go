//go:build fbmac && cgo

package main

/*
#include <stdint.h>
#include <stdlib.h>
typedef const char FBConstChar;
*/
import "C"

import (
	"encoding/json"
	"errors"
	"io"
	"unsafe"
)

// All returned strings are C allocations owned by the caller. Swift must call
// FBFree exactly once. Numeric handles never contain Go pointers. FBResponse
// and FBRead block and must be called off the main thread. Cancel interrupts
// either call. Finish releases the handle after the reader has stopped.

func desktopCString(value any) *C.char {
	data, err := json.Marshal(value)
	if err != nil {
		return C.CString(`{"error":"cannot encode bridge response"}`)
	}
	return C.CString(string(data))
}

//export FBCreate
func FBCreate(root, pandoc *C.FBConstChar) *C.char {
	if root == nil || pandoc == nil {
		return desktopCString(map[string]string{"error": "root and pandoc paths are required"})
	}
	id, err := registerDesktopEngine(C.GoString((*C.char)(unsafe.Pointer(root))), C.GoString((*C.char)(unsafe.Pointer(pandoc))))
	if err != nil {
		return desktopCString(map[string]string{"error": err.Error()})
	}
	return desktopCString(map[string]uint64{"engine": id})
}

//export FBDestroy
func FBDestroy(engine C.uint64_t) { destroyDesktopEngine(uint64(engine)) }

//export FBStart
func FBStart(engine C.uint64_t, requestJSON *C.FBConstChar) C.uint64_t {
	var input string
	if requestJSON != nil {
		input = C.GoString((*C.char)(unsafe.Pointer(requestJSON)))
	}
	return C.uint64_t(startDesktopRequest(uint64(engine), input))
}

//export FBResponse
func FBResponse(requestID C.uint64_t) *C.char {
	request := getDesktopRequest(uint64(requestID))
	if request == nil {
		return desktopCString(desktopResponse{Error: "unknown or finished request", Headers: map[string]string{}})
	}
	return desktopCString(request.metadata())
}

//export FBRead
func FBRead(requestID C.uint64_t, buffer unsafe.Pointer, capacity C.int64_t) C.int64_t {
	// The native implementation uses 64 KiB chunks. Bound the temporary view
	// even if a corrupt caller passes a value that overflows a Go int.
	if buffer == nil || capacity <= 0 || capacity > 16<<20 {
		return -1
	}
	request := getDesktopRequest(uint64(requestID))
	if request == nil {
		return -1
	}
	n, err := request.body.Read(unsafe.Slice((*byte)(buffer), int(capacity)))
	if n > 0 {
		return C.int64_t(n)
	}
	if err == nil || errors.Is(err, io.EOF) {
		return 0
	}
	return -1
}

//export FBCancel
func FBCancel(requestID C.uint64_t) {
	if request := getDesktopRequest(uint64(requestID)); request != nil {
		request.cancel()
	}
}

//export FBFinish
func FBFinish(requestID C.uint64_t) { finishDesktopRequest(uint64(requestID)) }

//export FBFree
func FBFree(pointer unsafe.Pointer) { C.free(pointer) }
