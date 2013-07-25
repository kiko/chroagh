// Copyright (c) 2013 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

var DEBUG = false; //FIXME: Implement
var URL = "ws://localhost:30001/";
var VERSION = "0";

var clipboardholder_;
//var logger_; //FIXME: Implement
var websocket_;

var error_ = false;

function clipboardStart() {
    printDebug("Crouton extension running!");

    clipboardholder_ = document.getElementById("clipboardholder");

    websocketConnect();
}

function websocketConnect() {
    printDebug("Opening a web socket");
    websocket_ = new WebSocket(URL);
    websocket_.onopen = websocketOpen;
    websocket_.onmessage = websocketMessage;
    websocket_.onclose = websocketClose;
}

function websocketOpen() {
    printDebug("Connection established.");
    websocket_.send("V"); /* Request version */
}

function websocketMessage(evt) {
    var received_msg = evt.data;
    var cmd = received_msg[0];
    var payload = received_msg.substring(1);

    printDebug("Message is received (" + cmd + "+" + received_msg + ")");

    switch(cmd) {
    case 'V':
        if (payload != VERSION) {
            printError("Invalid server version " + payload + " != " + VERSION + ".");
        }
    case 'W':
        clipboardholder_.value = payload;
        clipboardholder_.select();
        document.execCommand("Copy");
        websocket_.send("WOK");
        break;
    case 'R':
        clipboardholder_.value = "";
        clipboardholder_.select();
        document.execCommand("Paste");
        websocket_.send("R" + clipboardholder_.value);
        break;
    case 'E':
        printError("Server error: " + payload);
        break;
    default:
        printError("Invalid packet from server: " + received_msg);
        break;
    }
}

function websocketClose() {
    if (!error_) {
        printDebug("Connection is closed, try again in 5 seconds...");
        /* Retry in 5 seconds */
        setTimeout(websocketConnect, 5000);
    } else {
        printDebug("Connection is closed after an error, not retrying.");
    }
}

function printDebug(str) {
    console.log(str);
    if (DEBUG) {
        //logger_.textContent += str + "\n";
    }
}

function printError(str) {
    // FIXME: Do something better
    console.log(str);
    error_ = true;
    websocket_.close();
}

document.addEventListener('DOMContentLoaded', clipboardStart);

