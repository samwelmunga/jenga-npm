/**
 * @file project/app/api/parsers/git-log.js
 * Reads git log history as an array of commit objects.
 */

const { execFile } = require('child_process');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '../../../..');
const SEP = '|||';
const FORMAT = `%H${SEP}%an${SEP}%aI${SEP}%s${SEP}%b`;

/**
 * Run git log and return parsed commit entries.
 * Returns [] if not a git repo or git is unavailable.
 * @returns {Promise<Object[]>}
 */
function readGitLog() {
  return new Promise((resolve) => {
    execFile(
      'git',
      ['log', `--format=${FORMAT}`, '--max-count=200'],
      { cwd: REPO_ROOT, timeout: 10000 },
      (err, stdout) => {
        if (err) {
          // Not a git repo or git unavailable — return empty
          return resolve([]);
        }
        const commits = stdout
          .split('\n')
          .filter((line) => line.includes(SEP))
          .map((line) => {
            const [sha, author, date, subject, ...bodyParts] = line.split(SEP);
            return {
              type: 'git_commit',
              sha: sha.trim(),
              author: author.trim(),
              date: date.trim(),
              subject: subject.trim(),
              body: bodyParts.join(SEP).trim(),
            };
          })
          .filter((c) => c.sha);
        resolve(commits);
      }
    );
  });
}

module.exports = { readGitLog };
