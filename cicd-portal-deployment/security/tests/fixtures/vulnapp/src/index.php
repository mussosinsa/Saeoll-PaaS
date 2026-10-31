<?php
$id = $_GET['id'];
$rows = $db->query("SELECT * FROM post WHERE id = " . $id);
echo $_GET['name'];
system($_GET['cmd']);
system("ls -al");
eval($code);
$hash = md5($password);
$obj = unserialize($_COOKIE['data']);
include $_GET['page'];
$ok = $db->prepare("SELECT * FROM post WHERE id = ?");
