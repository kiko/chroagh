var DEBUG = false;
var ADDRESS = "127.0.0.1";
var PORT = 30001;

var appwin_; // Application window
var socketId_; // Listen socket Id
var acceptId_; // Accept socket Id
var reading_ = false; // Currently reading a second block of data

var document_;
var clipboardholder_;
var logger_;
var info_;

function clipboardStart() {
    console.log("start!");

    chrome.app.window.create('window.html', {
        'id': 'croutonclip',
        'bounds': {
            'width': 400,
            'height': 300
        },
        'hidden': !DEBUG
        },
        function(win) {
            appwin_ = win;
            // See http://code.google.com/p/chromium/issues/detail?id=148522
            win.contentWindow.addEventListener("load", appWindowCallback);
        }
    );
}

function appWindowCallback() {
    document_ = appwin_.contentWindow.document;
    clipboardholder_ = document_.getElementById("clipboardholder");
    logger_ = document_.getElementById("logger");
    info_ = document_.getElementById("info");

    printDebug("appWindowCallback");

    chrome.socket.create('tcp', {}, function(createInfo) {
        socketId_ = createInfo.socketId;
        chrome.socket.listen(socketId_, ADDRESS, PORT, function(result) {
            printDebug("listen (" + result + ")");
            if (result < 0) {
                printError("Cannot listen on " + ADDRESS + ":" + PORT +
                    ": Is the port already in use by another application?");
                return;
            }
            chrome.socket.accept(socketId_, onSocketAccept);
        });
    });

    appwin_.onClosed.addListener(clipboardStop());
}

function onSocketAccept(acceptInfo) {
    acceptId_ = acceptInfo.socketId;
    printDebug("accept");
    if (acceptInfo.resultCode < 0) {
        printError("Error on accept.");
        // FIXME: Try to accept a new connection? Or bail out?
        return;
    }

    readNext(false);
}

function readNext(reading) {
    reading_ = reading;
    chrome.socket.read(acceptId_, onSocketRead);
}

function onSocketRead(readInfo) {
    printDebug("read(" + readInfo.resultCode + ")");

    if (readInfo.resultCode < 0) {
        if (reading_) {
            printDebug("copy (" + clipboardholder_.value + ")");
            reading_ = false;
            clipboardholder_.style.display = "block";
            clipboardholder_.select();
            document_.execCommand("Copy");
            clipboardholder_.style.display = "none";
            acceptNext();
            return;
        }
    }

    var data = arrayBufferToString(readInfo.data, 0);

    printDebug("read(data=" + data + ")");

    if (reading_ || (data.length > 0 && data[0] == 'P')) {
        // Copy data to clipboard
        clipboardholder_.style.display = "block";
        if (!reading_) {
            reading_ = true;
            clipboardholder_.value = data.substring(1);
        } else {
            clipboardholder_.value += data;
        }
        readNext(true);
    } else {
        clipboardholder_.style.display = "block";
        clipboardholder_.value = "";
        clipboardholder_.select();
        document_.execCommand("Paste");
        clipboardholder_.style.display = "none";
        var clipdata = clipboardholder_.value;
        var clipdataarray = stringToUint8Array(clipdata);
        var outputBuffer = new ArrayBuffer(clipdataarray.byteLength);
        var view = new Uint8Array(outputBuffer)
        view.set(clipdataarray, 0);

        printDebug("clip(" + clipdata + ")");
        chrome.socket.write(acceptId_, outputBuffer, onSocketWrite);
    }
}

function onSocketWrite(writeInfo) {
    // FIXME: Check that all the bytes have been written?
    printDebug("write(" + writeInfo.bytesWritten + ")");
    acceptNext();
}

function acceptNext() {
    chrome.socket.destroy(acceptId_);
    chrome.socket.accept(socketId_, onSocketAccept);
}

function clipboardStop() {
    chrome.socket.destroy(socketId_);
}

// Copied from chrome-app-samples/webserver
function stringToUint8Array(string) {
    var buffer = new ArrayBuffer(string.length);
    var view = new Uint8Array(buffer);
    for(var i = 0; i < string.length; i++) {
      view[i] = string.charCodeAt(i);
    }
    return view;
};

// Copied from chrome-app-samples/webserver
function arrayBufferToString(buffer, index) {
    var str = '';
    var uArrayVal = new Uint8Array(buffer);
    for(var s = index; s < uArrayVal.length; s++) {
        str += String.fromCharCode(uArrayVal[s]);
    }
    return str;
};

function printDebug(str) {
    console.log(str);
    if (DEBUG) {
        logger_.textContent += str + "\n";
    }
}

function printError(str) {
    var info = appwin_.contentWindow.document.getElementById("info");
    info.textContent = str;
    /* Make sure the window gets visible */
    appwin_.show();
    appwin_.drawAttention();
}

chrome.app.runtime.onLaunched.addListener(function() {
    clipboardStart();
});

chrome.app.runtime.onSuspend.addListener(function() {
    clipboardStop();
});

