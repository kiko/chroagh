// Copyright (c) 2013 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

var DEBUG = true;
var URL = "ws://localhost:30001/";
var VERSION = "0";

var clipboardholder_;
var websocket_;

var error_ = false;

var status_ = "";
var errortext_ = "";
var logger_ = [];

function setStatus(status, online) {
    chrome.browserAction.setIcon({path: online ? "icon-online.png" : "icon-offline.png"});

    status_ = status;
    refreshPopup();
}

refreshPopup = function() {
    var views = chrome.extension.getViews({type: "popup"});
    for (var i = 0; i < views.length; views++) {
        var info = views[i].document.getElementById("info");
        if (info) info.textContent = status_;
        var error = views[i].document.getElementById("error");
        if (error) error.textContent = errortext_;
        var logger = views[i].document.getElementById("logger");
        if (logger) logger.textContent = logger_.join('\n');
    }
}

function clipboardStart() {
    printDebug("Crouton extension running!");
    setStatus("Started...", false);

    clipboardholder_ = document.getElementById("clipboardholder");

    websocketConnect();
}

function websocketConnect() {
    printDebug("Opening a web socket");
    setStatus("Connecting...", false);
    errortext_ = "";
    websocket_ = new WebSocket(URL);
    websocket_.onopen = websocketOpen;
    websocket_.onmessage = websocketMessage;
    websocket_.onclose = websocketClose;
}

function websocketOpen() {
    printDebug("Connection established.");
    setStatus("Connection established: checking version...", false);
    websocket_.send("V"); /* Request version */
}

function websocketMessage(evt) {
    var received_msg = evt.data;
    var cmd = received_msg[0];
    var payload = received_msg.substring(1);

    printDebug("Message is received (" + cmd + "+" + received_msg + ")");

    switch(cmd) {
    case 'V':
        /* FIXME: This needs to be stateful (do not answer anything else until we get the version back) */
        if (payload != VERSION) {
            printError("Invalid server version " + payload + " != " + VERSION + ".");
        }
        setStatus("Connection established.", true);
        break;
    case 'W':
        clipboardholder_.value = "";
        clipboardholder_.select();
        document.execCommand("Paste");
        /* Do not erase identical clipboard content */
        if (clipboardholder_.value != payload) {
            clipboardholder_.value = payload;
            clipboardholder_.select();
            /* FIXME: Cannot copy empty text, this is a problem with binary data in Linux. */
            document.execCommand("Copy");
        } else {
            printDebug("Not erasing content (identical).");
        }
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
        setStatus("No connection (retrying in 5 seconds)", false);
        printDebug("Connection is closed, try again in 5 seconds...");
        /* Retry in 5 seconds */
        setTimeout(websocketConnect, 5000);
    } else {
        setStatus("No connection (error: not retrying).", false);
        printDebug("Connection is closed after an error, not retrying.");
    }
}

function printDebug(str) {
    if (str.length > 80)
        str = str.substring(0, 77) + "...";
    console.log(str);
    if (DEBUG) {
        logger_.unshift(str);
        if (logger_.length > 20) {
            logger_.pop();
        }
        refreshPopup();
    }
}

function printError(str) {
    // FIXME: Do something better
    console.log(str);
    error_ = true;
    errortext_ = str;
    refreshPopup();
    websocket_.close();
}

document.addEventListener('DOMContentLoaded', clipboardStart);

