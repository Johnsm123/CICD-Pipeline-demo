const express = require("express");

const app = express();
const port = process.env.PORT || 8080;
const version = process.env.APP_VERSION || "v7";

app.get("/", (req, res) => {
  res.json({
    message: "Deployed all by AWS CodePipeline! Hello the demo by John",
    version,
    hostname: require("os").hostname(),
    timestamp: new Date().toISOString(),
  });
});

app.get("/health", (req, res) => {
  res.status(200).json({ status: "ok" });
});

app.listen(port, () => {
  console.log(`App listening on port ${port} (version ${version})`);
});
