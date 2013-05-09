// FIXME: Add error checking everywhere...
// Could the window be in the background? Or do we want it anyway?

// Port 30001 is guaranteed not to be taken by random outgoing connections,
// since /proc/sys/net/ipv4/ip_local_port_range = "32768	61000"

var appwin;
var socketInfo;

function clipboardStart() {
    console.log("start!");

    chrome.app.window.create('window.html', {
        'bounds': {
        'width': 400,
        'height': 500
        }},
        function(win) {
            console.log("win create!");
            appwin = win;
            win.contentWindow.addEventListener("load", appWindowCallback);
        }
    );

    chrome.socket.create('tcp', {}, function(createInfo) {
        socketInfo = createInfo;
        chrome.socket.listen(socketInfo.socketId, "127.0.0.1", 30001, function(connection) {
            printDebug("--listen");
            chrome.socket.accept(socketInfo.socketId, onSocketAccept);
        });
    });
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

function onSocketAccept(acceptInfo) {
    console.log("Accept!");
    printDebug("--accept");

    var asocketId = acceptInfo.socketId;

    chrome.socket.read(asocketId, function(readInfo) {
        // FIXME: We assume that all the data will fit in a single read
        var data = arrayBufferToString(readInfo.data, 0);

        printDebug("--read(" + data + ")");

        var document = appwin.contentWindow.document;

        clipboardholder= document.getElementById("clipboardholder");

        if (data.length > 0 && data[0] == 'P') {
            // Copy data to clipboard
            clipboardholder= document.getElementById("clipboardholder");
            clipboardholder.style.display = "block";
            clipboardholder.value = data.substring(1);
            clipboardholder.select();
            document.execCommand("Copy");
            clipboardholder.style.display = "none";
        } else {
            clipboardholder.style.display = "block";
            clipboardholder.value = "";
            clipboardholder.select();
            document.execCommand("Paste");
            clipboardholder.style.display = "none";
            var clipdata = clipboardholder.value;
            var clipdataarray = stringToUint8Array(clipdata);
            var outputBuffer = new ArrayBuffer(clipdataarray.byteLength);
            var view = new Uint8Array(outputBuffer)
            view.set(clipdataarray, 0);

            printDebug("--clip(" + clipdata + ")");
            chrome.socket.write(acceptInfo.socketId, outputBuffer, function(value) {
                printDebug("--write(" + value.bytesWritten + ")");
            });
        }

        chrome.socket.destroy(acceptInfo.socketId);
        chrome.socket.accept(socketInfo.socketId, onSocketAccept);
    });
}

function appWindowCallback() {
    console.log("callback!");
    printDebug("--test");
}

function printDebug(str) {
    appwin.contentWindow.document.body.appendChild(appwin.contentWindow.document.createTextNode(str));
}

chrome.app.runtime.onLaunched.addListener(function() {
    clipboardStart();
});
  

