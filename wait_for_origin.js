var http = require('http');
var zmq = require("zeromq");

function parseMessage(ch, msg) {
	return msg.toString('utf8').replace(ch + ' ', '');
}

http.createServer(function (request, response) {
	var s = zmq.createSocket("sub");
	
	var url = require('url').parse(request.url, true)
	var ch = url.query.channel;
	
	s.subscribe(ch);
	s.connect('tcp://*:5601');
	console.log("Connected, subscribed to: " + ch);
	
	s.on('message', function(data) {
		var messages = arguments; 	// data is sent with ZMQ.SNDMORE
									// so we get it atomically
		
		var status = 500;
		var body = "";
		
		for (i = 0; i < messages.length; i++) {
			msg = messages[i].toString('utf8');
			
			switch (msg) {
			case ch + ':header':
				response.setHeader(parseMessage(ch, messages[i+1]), parseMessage(ch, messages[i+2]));
				break;
			case ch + ':status':
				status = parseMessage(ch, messages[i+1]);
				break;
			case ch + ':body':
				body = parseMessage(ch, messages[i+1]);
				break;
			case ch + ':end':
				s.close();
			
				console.log("Finished " + ch + " with status " + status)
				response.writeHead(status);
				response.end(body);
				
				break;
			}
		}
	});
	
	
}).listen(1337, "127.0.0.1");

console.log('Server running at http://127.0.0.1:1337/');
