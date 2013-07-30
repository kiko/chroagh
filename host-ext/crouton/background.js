// Copyright (c) 2013 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/* Constants */
var URL = "ws://localhost:30001/";
var VERSION = "0";
var MAXLOGGERLEN = 20;

LogLevel = {
    ERROR : 0,
    INFO : 1,
    DEBUG : 2
}

var clipboardholder_;
var timeout_ = null;
var websocket_ = null;

var debug_ = false;
var enabled_ = true; /* true if we are trying to connect */
var active_ = false; /* true if we are connected to a server */

var status_ = "";
var logger_ = [];

function setStatus(status, active) {
    active_ = active;
    /* FIXME: Third icon when not enabled */

    chrome.browserAction.setIcon({path: active_ ? "icon-online.png" : "icon-offline.png"});

    status_ = status;
    refreshPopup();
}

refreshPopup = function() {
    var views = chrome.extension.getViews({type: "popup"});
    for (var i = 0; i < views.length; views++) {
        if (document.readyState === "complete") {
            /* FIXME: There is a little box coming around the link, why? */
            enablelink = views[i].document.getElementById("enable");
            if (enabled_) {
                enablelink.textContent = "Disable";
                enablelink.onclick = function() {
                    console.log("Disable click");
                    enabled_ = false;
                    if (websocket_ != null)
                        websocket_.close();
                    else
                        websocketConnect(); /* Clear timeout and display message */
                    refreshPopup();
                }
            } else {
                enablelink.textContent = "Enable";
                enablelink.onclick = function() {
                    console.log("Enable click");
                    enabled_ = true;
                    if (websocket_ == null)
                        websocketConnect();
                    refreshPopup();
                }
            }

            debugcheck = views[i].document.getElementById("debugcheck");
            debugcheck.onclick = refreshPopup;
            debug_ = debugcheck.checked;

            views[i].document.getElementById("info").textContent = status_;
            loggertable = views[i].document.getElementById("logger");

            /* FIXME: only update needed rows */
            while (loggertable.rows.length > 0) {
                loggertable.deleteRow(0);
            }

            for (i = 0; i < logger_.length; i++) {
                value = logger_[i];

                if (value[0] == LogLevel.DEBUG && !debug_)
                    continue;

                var row = loggertable.insertRow(-1);
                var cell1 = row.insertCell(0);
                var cell2 = row.insertCell(1);
                var levelclass = "debug";
                switch (value[0]) {
                case LogLevel.ERROR:
                    levelclass = "error";
                    break;
                case LogLevel.INFO:
                    levelclass = "info";
                    break;
                case LogLevel.DEBUG:
                default:
                    levelclass = "debug";
                    break;
                }
                cell1.className = "time " + levelclass;
                cell2.className = "value " + levelclass;
                cell1.innerHTML = value[1];
                cell2.innerHTML = value[2];
            }
            //views[i].document.getElementById("logger").textContent = logger_.join('\n');
        }
    }
}

function clipboardStart() {
    printLog("Crouton extension running!", LogLevel.DEBUG);
    setStatus("Started...", false);

    clipboardholder_ = document.getElementById("clipboardholder");

    websocketConnect();
}

function websocketConnect() {
    if (timeout_ != null) {
        clearTimeout(timeout_); /* Clear timeout if we were called manually. */
        timeout_ = null;
    }

    if (!enabled_) {
        setStatus("No connection (extension disabled).", false);
        printLog("Extension is disabled.", LogLevel.INFO);
        return;
    }

    if (websocket_ != null) {
        printLog("Socket already open", LogLevel.DEBUG);
        return;
    }

    console.log("websocketConnect: " + websocket_);

    printLog("Opening a web socket", LogLevel.DEBUG);
    setStatus("Connecting...", false);
    websocket_ = new WebSocket(URL);
    websocket_.onopen = websocketOpen;
    websocket_.onmessage = websocketMessage;
    websocket_.onclose = websocketClose;
}

function websocketOpen() {
    printLog("Connection established.", LogLevel.INFO);
    setStatus("Connection established: checking version...", false);
    websocket_.send("V"); /* Request version */
}

function websocketMessage(evt) {
    var received_msg = evt.data;
    var cmd = received_msg[0];
    var payload = received_msg.substring(1);

    printLog("Message is received (" + cmd + "+" + received_msg + ")", LogLevel.DEBUG);

    /* Only accept version packets until we have checked the version. */
    if (!active_) {
        if (cmd == 'V') { /* Version */
            if (payload != VERSION) {
                error("Invalid server version " + payload + " != " + VERSION + ".", false);
            }
            setStatus("Connection established.", true);
            active_ = true;
            return;
        } else {
            error("Received frame while waiting for version.", false);
        }
    }

    switch(cmd) {
    case 'W': /* Write */
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
            printLog("Not erasing content (identical).", LogLevel.DEBUG);
        }
        websocket_.send("WOK");
        break;
    case 'R': /* Read */
        clipboardholder_.value = "";
        clipboardholder_.select();
        document.execCommand("Paste");
        websocket_.send("R" + clipboardholder_.value);
        break;
    case 'U': /* Open an URL */
        /* FIXME: Sanity check? We may not want people to open stuff like
         * javascript:alert("hello") */
        chrome.tabs.create({ url: payload });
        websocket_.send("UOK");
        break;
    case 'P': /* Ping */
        websocket_.send(received_msg);
        break;
    case 'E':
        error("Server error: " + payload, 1);
        break;
    default:
        error("Invalid packet from server: " + received_msg, 1);
        break;
    }
}

function websocketClose() {
    if (websocket_ == null) {
        console.log("websocketClose: null!");
        return;
    }

    if (enabled_) {
        setStatus("No connection (retrying in 5 seconds)", false);
        printLog("Connection is closed, trying again in 5 seconds...", LogLevel.INFO);
        /* Retry in 5 seconds */
        if (timeout_ == null) {
            timeout_ = setTimeout(websocketConnect, 5000);
        }
    } else {
        setStatus("No connection (extension disabled).", false);
        printLog("Connection is closed, extension is disabled: not retrying.", LogLevel.INFO);
    }
    websocket_ = null;
}

function padstr0(i) {
    var s = i + "";
    if (s.length < 2)
        return "0" + s;
    else
        return s;
}

function printLog(str, level) {
    date = new Date;
    datestr = padstr0(date.getHours()) + ":" +
          padstr0(date.getMinutes()) + ":" +
          padstr0(date.getSeconds());

    if (str.length > 80)
        str = str.substring(0, 77) + "...";
    console.log(datestr + ": " + str);
    /* Add to logger if this is not a debug message, or if debugging is enabled */
    if (level == LogLevel.ERROR || level == LogLevel.INFO || debug_) {
        logger_.unshift([level, datestr, str]);
        if (logger_.length > MAXLOGGERLEN) {
            logger_.pop();
        }
        refreshPopup();
    }
}

/* Display an error, and prevent retries if active is false */
function error(str, active) {
    printLog(str, LogLevel.ERROR);
    enabled_ = active;
    /* Display an error */
    refreshPopup();
    websocket_.close();
}

document.addEventListener('DOMContentLoaded', clipboardStart);
