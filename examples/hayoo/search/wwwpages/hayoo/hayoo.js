var lastPress = (new Date()).getTime();

document.observe("dom:loaded", function() {
	checkForQuery();
});

function checkForQuery () {
	var argument = window.location.search.gsub(/\+/, '%20').toQueryParams()['query'];
	
	if (argument) {
		$("querytext").value = argument;
		processQuery();
	}
}

function tryProcessQuery () {
	currentPress = (new Date()).getTime();
	delay = currentPress - lastPress;
	lastPress = currentPress;
	if (delay > 500) {
		processQuery(0);
	}
}

function forceProcessQuery () {
	processQuery(0);
	
	return false;
}

function processQuery (start) {
	var query = $("querytext").value;
	if (query.length > 1) {
		$("throbber").show();
		new Ajax.Request("results/hayoo.html?query=" + query + "&start=" + start,
		{
			method:'get',
			onSuccess: function(transport) {
				lastXMLResult = transport.responseXML;
				lastTXTResult = transport.responseText;
			  displayResult(transport.responseText);
			},
			onFailure: function(){ alert('Something went wrong...') }
		});
	}
}

function replaceInQuery (needle, substitute) {
	$("querytext").value = $("querytext").value.gsub(needle, substitute);
	processQuery();
}

function displayResult (result) {
	$("result").replace(result);
	
	$("throbber").hide();
}

function showPage (page) {
	processQuery (page);
}