const child_process = require("child_process");
const express = require("express");
app.get("/x", (req, res) => {
  child_process.exec("ls " + req.query.dir);
  db.query("SELECT * FROM t WHERE id = " + req.query.id);
  db.query(`SELECT * FROM t WHERE id = ${req.query.id}`);
  db.query("SELECT * FROM t WHERE id = ?", [req.query.id]);
  el.innerHTML = req.query.html;
  eval(req.query.code);
  res.setHeader("Access-Control-Allow-Origin", "*");
});
