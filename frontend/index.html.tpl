<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <title>Notes App - Serverless</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 40px; }
    #auth button { margin: 5px; padding: 10px 20px; }
    #createForm input, #createForm textarea { 
      margin: 5px 0; 
      padding: 8px; 
      width: 300px; 
      display: block;
    }
    #createForm button { padding: 10px 20px; margin-top: 10px; }
    .error { color: red; margin: 10px 0; }
    .success { color: green; margin: 10px 0; }
    .note-item { 
      margin: 10px 0; 
      padding: 10px; 
      border: 1px solid #ddd; 
      border-radius: 5px; 
    }
  </style>
</head>
<body>
  <h1>Notes App</h1>

  <div id="auth">
    <button id="btn-login">Login</button>
    <button id="btn-signup">Sign Up</button>
    <button id="btn-logout" style="display:none">Logout</button>
  </div>

  <div id="message"></div>

  <div id="app" style="display:none">
    <form id="createForm">
      <input id="title" placeholder="Title" required/><br/>
      <textarea id="content" placeholder="Content" required></textarea><br/>
      <button type="submit">Create Note</button>
    </form>

    <h2>Your notes</h2>
    <ul id="notesList"></ul>
  </div>

  <script>
  var COGNITO_DOMAIN = "${COGNITO_DOMAIN}";
  var CLIENT_ID = "${CLIENT_ID}";
  var REDIRECT_URI = "${REDIRECT_URI}";
  var API_BASE = "${API_BASE}";

  function showMessage(msg, isError) {
    var div = document.getElementById("message");
    div.textContent = msg;
    div.className = isError ? "error" : "success";
    console.log(isError ? "ERROR:" : "SUCCESS:", msg);
  }

  function openHostedUI(page) {
    var url = COGNITO_DOMAIN + "/" + page + "?response_type=token&client_id=" + CLIENT_ID + "&redirect_uri=" + encodeURIComponent(REDIRECT_URI) + "&scope=openid+profile+email";
    window.location = url;
  }

  function parseHash(hash) {
    if (!hash) return {};
    var h = hash.startsWith("#") ? hash.slice(1) : hash;
    return h.split("&").reduce(function(acc, kv) {
      var parts = kv.split("=");
      acc[parts[0]] = decodeURIComponent(parts[1] || "");
      return acc;
    }, {});
  }

  var tokens = parseHash(window.location.hash);
  console.log("Parsed tokens:", tokens);

  if (tokens.id_token) {
    sessionStorage.setItem("id_token", tokens.id_token);
    if (tokens.access_token) {
      sessionStorage.setItem("access_token", tokens.access_token);
    }
    history.replaceState({}, document.title, window.location.pathname);
  }

  var idToken = sessionStorage.getItem("id_token");

  document.getElementById("btn-login").onclick = function() { openHostedUI("login"); };
  document.getElementById("btn-signup").onclick = function() { openHostedUI("signup"); };
  document.getElementById("btn-logout").onclick = function() {
    sessionStorage.clear();
    location.reload();
  };

  if (idToken) {
    document.getElementById("btn-login").style.display = "none";
    document.getElementById("btn-signup").style.display = "none";
    document.getElementById("btn-logout").style.display = "inline";
    document.getElementById("app").style.display = "block";
    fetchNotes();
  }

  function apiRequest(path, method, body, callback) {
    var token = sessionStorage.getItem("id_token");
    if (!token) {
      showMessage("User not logged in", true);
      return;
    }

    console.log("API Request:", method, API_BASE + path);
    console.log("Token:", token.substring(0, 20) + "...");

    var headers = {
      "Authorization": "Bearer " + token,
      "Content-Type": "application/json"
    };

    var options = {
      method: method,
      headers: headers
    };

    if (body) {
      options.body = JSON.stringify(body);
      console.log("Request body:", body);
    }

    fetch(API_BASE + path, options)
      .then(function(response) {
        console.log("Response status:", response.status);
        if (!response.ok) {
          return response.text().then(function(text) {
            throw new Error("HTTP " + response.status + ": " + text);
          });
        }
        return response.json();
      })
      .then(function(data) {
        console.log("Response data:", data);
        if (callback) callback(null, data);
      })
      .catch(function(err) {
        console.error("API Error:", err);
        showMessage("Error: " + err.message, true);
        if (callback) callback(err, null);
      });
  }

  document.getElementById("createForm").onsubmit = function(e) {
    e.preventDefault();
    var title = document.getElementById("title").value;
    var content = document.getElementById("content").value;

    apiRequest("/notes", "POST", { title: title, content: content }, function(err, data) {
      if (err) return;
      showMessage("Note created successfully!", false);
      document.getElementById("title").value = "";
      document.getElementById("content").value = "";
      fetchNotes();
    });
  };

  function fetchNotes() {
    apiRequest("/notes", "GET", null, function(err, data) {
      if (err) return;
      var list = document.getElementById("notesList");
      list.innerHTML = "";

      var notes = data.items || [];
      console.log("Fetched notes:", notes.length);
      
      if (notes.length === 0) {
        list.innerHTML = "<li>No notes found. Create your first note!</li>";
      } else {
        notes.forEach(function(note) {
          var li = document.createElement("li");
          li.className = "note-item";
          li.textContent = note.title + " — " + note.content;
          list.appendChild(li);
        });
      }
    });
  }

  console.log("App initialized");
  console.log("API Base:", API_BASE);
  console.log("Has token:", !!idToken);
  </script>
</body>
</html>