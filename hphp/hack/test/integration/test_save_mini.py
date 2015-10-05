from __future__ import absolute_import
from __future__ import division
from __future__ import print_function
from __future__ import unicode_literals
import common_tests
import os
import subprocess
import unittest

from hh_paths import hh_server, hh_client
from utils import touch, proc_call, test_env

class TestSaveMiniState(common_tests.CommonSaveStateTests, unittest.TestCase):
    @classmethod
    def save_command(cls, init_dir):
        subprocess.call([
            hh_server,
            '--check', init_dir,
            '--save-mini', cls.saved_state_path()
        ], env=test_env)

    def write_load_config(self, *changed_files):
        with open(os.path.join(self.repo_dir, 'server_options.sh'), 'w') as f:
            f.write(r"""
#! /bin/sh
echo %s
""" % self.saved_state_path())
            os.fchmod(f.fileno(), 0o700)

        with open(os.path.join(self.repo_dir, 'hh.conf'), 'w') as f:
            # we can't just write 'echo ...' inline because Hack server will
            # be passing this command some command-line options
            f.write(r"""
# some comment
load_mini_script = %s
""" % os.path.join(self.repo_dir, 'server_options.sh'))

        touch(os.path.join(self.repo_dir, '.hhconfig'))

    def check_cmd(self, expected_output, stdin=None, options=None):
        options = [] if options is None else options
        root = self.repo_dir + os.path.sep
        output = proc_call([
            hh_client,
            'check',
            '--retries',
            '20',
            self.repo_dir
            ] + list(map(lambda x: x.format(root=root), options)),
            env={'HH_LOCALCONF_PATH': self.repo_dir},
            stdin=stdin)
        log_file = proc_call([hh_client, '--logname', self.repo_dir]).strip()
        with open(log_file) as f:
            logs = f.read()
            self.assertIn('Loading deps took', logs)
        self.assertCountEqual(
            map(lambda x: x.format(root=root), expected_output),
            output.splitlines())
