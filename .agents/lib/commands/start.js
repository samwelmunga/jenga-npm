import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const projectRoot = join(__dirname, "..", "..");

export async function runStart(args, root = projectRoot) {
  console.log(
    "The Jenga Router is now started automatically by your AI client (e.g. Claude) when it opens a session.\n" +
    "\n" +
    "To set this up for your project, run:\n" +
    "  jenga attach\n" +
    "\n" +
    "Then open a new AI session in this project — the router will start automatically via stdio."
  );
}
