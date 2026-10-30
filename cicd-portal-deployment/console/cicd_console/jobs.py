"""Run the CI/CD portal scripts (onboard-vendor.sh, add-app.sh, add-db.sh, check-cicd-portal.sh) in the
background and keep their output for the job pages.

One script runs at a time (the scripts change shared Keycloak/Harbor/Argo CD state); further jobs wait.
Jobs live in memory: the console runs as a single replica and the scripts are re-runnable.
"""
import collections
import datetime
import itertools
import logging
import os
import subprocess
import threading

from . import config

log = logging.getLogger("cicd-console")

MAX_JOBS = 50
_ids = itertools.count(1)
_jobs = collections.OrderedDict()
_lock = threading.Lock()          # protects _jobs
_run_lock = threading.Lock()      # one script at a time


class Job:
    def __init__(self, title, script, args, env, user, secrets):
        self.id = str(next(_ids))
        self.title = title
        self.script = script
        self.args = list(args)
        self.env = env
        self.user = user
        self.secrets = [s for s in secrets if s]
        self.created = datetime.datetime.now(datetime.timezone.utc)
        self.started = None
        self.ended = None
        self.rc = None
        self.lines = []

    @property
    def command(self):
        return " ".join([f"./{self.script}", *self.args])

    @property
    def status(self):
        if self.rc is None:
            return "running" if self.started else "pending"
        return {0: "success", 3: "manual"}.get(self.rc, "failed")

    def mask(self, line):
        for s in self.secrets:
            line = line.replace(s, "****")
        return line

    def run(self):
        with _run_lock:
            self.started = datetime.datetime.now(datetime.timezone.utc)
            log.info("job %s start by %s: %s", self.id, self.user, self.command)
            env = dict(os.environ)
            env.update(self.env)
            env["TERM"] = "dumb"
            try:
                proc = subprocess.Popen(["bash", self.script, *self.args], cwd=config.SCRIPT_DIR, env=env,
                                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True, bufsize=1)
                with proc.stdout:
                    for line in proc.stdout:
                        self.lines.append(self.mask(line.rstrip("\n")))
                self.rc = proc.wait()
            except OSError as e:
                self.lines.append(f"[ERROR] {e}")
                self.rc = 1
            self.env = {}   # drop passwords given for this run
            self.ended = datetime.datetime.now(datetime.timezone.utc)
            log.info("job %s end rc=%s", self.id, self.rc)


def start(title, script, args, user, env=None, secrets=()):
    job = Job(title, script, args, env or {}, user, secrets)
    with _lock:
        _jobs[job.id] = job
        while len(_jobs) > MAX_JOBS:
            oldest = next(iter(_jobs.values()))
            if oldest.rc is None:
                break
            _jobs.popitem(last=False)
    threading.Thread(target=job.run, name=f"job-{job.id}", daemon=True).start()
    return job


def get(job_id):
    return _jobs.get(str(job_id))


def all_jobs():
    with _lock:
        return list(reversed(_jobs.values()))
