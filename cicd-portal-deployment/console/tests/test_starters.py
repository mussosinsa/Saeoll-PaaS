"""Starters: the build dependency script (company Nexus, closed network) is the same everywhere and wired in."""
import os
import pathlib
import subprocess
import tempfile
import unittest

STARTERS = pathlib.Path(os.environ["CICD_SCRIPT_DIR"]).parent / "starters"
TYPES = ["java-gradle", "java-maven", "node", "php", "vue"]


class StartersTest(unittest.TestCase):
    def test_cicd_deps_copies(self):
        shared = (STARTERS / "_shared" / "cicd-deps.sh").read_text()
        for t in TYPES:
            self.assertEqual((STARTERS / t / "cicd-deps.sh").read_text(), shared, t)

    def test_wired_in(self):
        for t in TYPES:
            jf = (STARTERS / t / "Jenkinsfile").read_text()
            self.assertIn("def nexusUrl = '{CICD_NEXUS_URL}'", jf)
            self.assertEqual(jf.count("sh depsInit + "), 2, t)                  # build and test
            self.assertIn('--build-arg "NEXUS_URL=$NEXUS_URL"', jf)
            df = (STARTERS / t / "Dockerfile").read_text()
            self.assertIn("ARG NEXUS_URL", df, t)
            self.assertIn("cicd-deps.sh", df, t)
            self.assertIn(".cicd-deps", (STARTERS / t / ".dockerignore").read_text(), t)

    def test_script(self):
        script = STARTERS / "_shared" / "cicd-deps.sh"
        with tempfile.TemporaryDirectory() as d:
            def run(url):
                env = dict(os.environ, NEXUS_URL=url)
                return subprocess.run(["sh", "-c", f'. {script}; echo "$npm_config_registry|$MAVEN_ARGS|$COMPOSER_HOME"'],
                                      cwd=d, env=env, capture_output=True, text=True, check=True).stdout.strip().splitlines()[-1]
            self.assertEqual(run(""), "||")                                     # no Nexus: nothing changes
            self.assertEqual(run("$CICD_NEXUS_URL"), "||")                      # unset GitLab variable
            npm, maven, composer = run("http://nexus:8081/").split("|")
            self.assertEqual(npm, "http://nexus:8081/repository/npm-public/")
            self.assertIn("settings.xml", maven)
            settings = (pathlib.Path(d) / ".cicd-deps" / "settings.xml").read_text()
            self.assertIn("<url>http://nexus:8081/repository/maven-public/</url>", settings)
            self.assertIn("maven-default-http-blocker", settings)
            self.assertTrue((pathlib.Path(composer) / "config.json").exists())


if __name__ == "__main__":
    unittest.main()
