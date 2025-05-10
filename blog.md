# Building News Agents for Daily News Recaps with MCP, Q, and tmux

*Note: This post documents my experience forking and experimenting with the excellent [news-agents](https://github.com/eugeneyan/news-agents) project originally developed by Eugene Yan. All credit for the system design and code goes to Eugene; what follows is my journey of discovery, setup, and learning as a user and tinkerer.*

---

Curious about MCPs and agentic workflows, I forked Eugene Yan's news-agents repo to see if I could generate a daily news recap in my own environment. The project is built on [Amazon Q CLI](https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/command-line.html) and [MCP](https://modelcontextprotocol.io/), with tmux for spawning and displaying each sub-agent's work. Here's how Eugene's system is designed to work:

```
Main Agent (in the main tmux pane)
├── Read feeds.txt
├── Split feeds into 3 chunks
├── Spawns 3 Sub-Agents (in separate tmux panes)
│   ├── Sub-Agent #1
│   │   ├── Process feeds in chunk 1
│   │   └── Report back when done
│   ├── Sub-Agent #2
│   │   ├── Process feeds in chunk 2
│   │   └── Report back when done
│   └── Sub-Agent #3
│       ├── Process feeds in chunk 3
│       └── Report back when done
└── Combine everything into main-summary.md

```

Eugene's blog and code walk through how the MCP tools are built and how the main agent spawns and monitors sub-agents. Each sub-agent processes its allocated news feeds and generates summaries for each feed. The main agent then combines these summaries into a final summary. (Check out Eugene's three-minute 1080p demo—highly recommended!)

---

## My Experience: Forking, Setting Up, and Discovering

When I tried to set up the project according to the [README](https://github.com/eugeneyan/news-agents/blob/main/README.md), I encountered some of the same issues and discoveries Eugene describes in his blog. This section shares my hands-on experience, what worked, what didn't, and what I learned along the way.

### Setting up MCPs for news feeds

Eugene's code provides a separate RSS reader, parser, and formatter for each news feed. These handle the unique structure and format of each feed. (In the future, maybe an LLM could parse these blobs reliably and cheaply!) For example, here's Eugene's code for fetching and parsing the Hacker News RSS feed:

```
async def fetch_hn_rss(feed_url: str) -> str:
    """
    Fetch Hacker News RSS feed.

    Args:
        feed_url: URL of the RSS feed to fetch (defaults to Hacker News)
    """
    headers = {"User-Agent": USER_AGENT}
    async with httpx.AsyncClient() as client:
        try:
            response = await client.get(feed_url, headers=headers, timeout=10.0)
            response.raise_for_status()
            return response.text
        except httpx.HTTPError as e:
            return f"HTTP Error fetching RSS: {str(e)}"
        except httpx.TimeoutException:
            return f"Timeout fetching RSS from {feed_url}"
        except Exception as e:
            return f"Error fetching RSS: {str(e)}"


def parse_hn_rss(rss_content: str) -> List[Dict[str, Any]]:
    """Parse RSS content into a list of story dictionaries."""
    stories = []
    try:
        root = ET.fromstring(rss_content)
        items = root.findall(".//item")

        for item in items:
            story = {
                "title": item.find("title").text
                if item.find("title") is not None
                else "No title",
                "link": item.find("link").text if item.find("link") is not None else "",
                "description": item.find("description").text
                if item.find("description") is not None
                else "No description",
                "pubDate": item.find("pubDate").text
                if item.find("pubDate") is not None
                else "",
                # Any other fields we want to extract
            }
            stories.append(story)

        return stories
    except Exception as e:
        return [{"error": f"Error parsing RSS: {str(e)}"}]

```


The MCP server then imports these parsers and sets up the MCP tools. MCP makes it easy to set up tools with the `@mcp.tool()` decorator. For example, here's the Hacker News tool:

```
# Initialize FastMCP server
mcp = FastMCP("news-mcp")


@mcp.tool()
async def get_hackernews_stories(
    feed_url: str = DEFAULT_HN_RSS_URL, count: int = 30
) -> str:
    """Get top stories from Hacker News.

    Args:
        feed_url: URL of the RSS feed to use (default: Hacker News)
        count: Number of stories to return (default: 5)
    """
    rss_content = await fetch_hn_rss(feed_url)
    if rss_content.startswith("Error"):
        return rss_content

    stories = parse_hn_rss(rss_content)

    # Limit to requested count
    stories = stories[: min(count, len(stories))]

    if not stories:
        return "No stories found."

    formatted_stories = [format_hn_story(story) for story in stories]
    return "\n---\n".join(formatted_stories)

```


With this, here's the tools that our agent has from both news-mcp and the built-ins:

```
> /tools
bloh
Tool                                          Permission
▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
news_mcp (MCP):
- news_mcp___get_wired_stories                * not trusted
- news_mcp___get_techcrunch_stories           * not trusted
- news_mcp___get_wallstreetjournal_stories    * not trusted
- news_mcp___get_hackernews_stories           * not trusted
- news_mcp___get_ainews_latest                * not trusted

Built-in:
- fs_write                                    * not trusted
- execute_bash                                * trust read-only commands
- report_issue                                * trusted
- fs_read                                     * trusted
- use_aws                                     * trust read-only commands

```


Setting up agents to process news
---------------------------------

Next, we'll set up a multi-agent system to parse the news feeds and generate summaries. We'll have a main agent (image below, top-left) that coordinates three sub-agents, each running in a separate tmux window (image below; bottom-left and right panes).

![The main agent (top-left) with its newly spawned sub-agents](https://eugeneyan.com/assets/news-agents.jpg "The main agent (top-left) with its newly spawned sub-agents")

The main agent (top-left) with its newly spawned sub-agents

The main agent will first divide the news feeds into three groups. Then, it'll spawn three sub-agents, each assigned to a group of news feeds. In the demo, these sub-agents are displayed as a separate tmux window for each sub-agent.

```
# Main Agent - Multi-Agent Task Coordinator

## Role

You are the primary coordinating agent responsible for distributing tasks among 
sub-agents and aggregating their results. 
- Read feeds.txt for the input feeds
- Read context/sub-agent.md to understand your sub agents
- Return the summary in the format of context/main-summary-template.md

## Task Assignment Instructions

Use the following message format when assigning tasks: "You are Agent [NUMBER]. 
Read the instructions at /context/sub-agent.md and execute it. Here are the 
feeds to process: [FEEDS]"

...

```


Truncated instructions for main agent

Then, the sub-agents will process their assigned news feeds and generate summaries for each of them. The sub-agent also categorizes stories within each feed, such as AI/ML, technology, business, etc. Throughout this process, the sub-agents display status updates. When the sub-agent finishes processing its assigned feeds, it displays a final completion status.

```
# Sub-Agent - Task Processor

## Role

You are a specialized processing agent designed to execute assigned tasks 
independently while reporting progress to the main coordinating agent. 
Process each feed individually and completely before moving to the next one. 
Write the summaries to summaries/ which has already been created. 
Return the summary in the format of context/sub-summary-template.md.

...

```


Truncated instructions for sub-agent

While the sub-agents are processing their assigned feeds, the main agent monitors their progress. When all sub-agents are done, the main agent reads the individual feed summaries and combines them into a final summary.

Defining the news feeds
-----------------------

Finally, we define the news feeds in [feeds.txt](https://github.com/eugeneyan/news-agents/blob/main/feeds.txt) below. We have six feeds: Hacker News, The Wall Street Journal Tech, The Wall Street Journal Markets, TechCrunch, AI News, and Wired.

```
hackernews: https://news.ycombinator.com/rss
wsj-tech: https://feeds.content.dowjones.io/public/rss/RSSWSJD
wsj-markets: https://feeds.content.dowjones.io/public/rss/RSSMarketsMain
techcrunch: https://techcrunch.com/feed/
ainews: https://news.smol.ai/rss.xml
wired: https://www.wired.com/feed/tag/ai/latest/rss

```


And here's the truncated [main-summary](https://github.com/eugeneyan/news-agents/blob/main/summaries/main-summary.md) it generated for 4th May.

```
# News for May 4, 2025

### Global Statistics
- **Total Items Across Sources:** 124
- **Sources:** 6 (Hacker News, WSJ Tech, WSJ Markets, TechCrunch, AI News, Wired)
- **Date Range Covered:** May 2-4, 2025
- **Total Categories Identified:** 42

### Category Distribution
| Category | Count | Percentage | Top Source |
|----------|-------|------------|------------|
| AI/Machine Learning | 31 | 25% | AI News |
| Business/Finance | 18 | 14.5% | WSJ Markets |
| Technology | 16 | 12.9% | Hacker News |
| Politics/Government | 7 | 5.6% | Wired |
| Cybersecurity/Privacy | 6 | 4.8% | TechCrunch |
| Trade Policy | 6 | 4.8% | WSJ Markets |

---

## Cross-Source Trends

### Global Top 5 Topics

1. **AI Integration Across Industries**
   - Mentions across sources: 31
   - Key sources: AI News, WSJ Tech, TechCrunch, Wired
   - Representative headlines: "AI Agents Are Learning How to Collaborate. Companies 
     Need to Work With Them", "Agent-to-Agent (A2A) Collaboration", "Nvidia CEO Says 
     All Companies Will Need 'AI Factories'"

2. **Trade Policy and Tariff Impact**
   - Mentions across sources: 12
   - Key sources: WSJ Markets, TechCrunch, WSJ Tech
   - Representative headlines: "Temu stops shipping products from China to the U.S.", 
     "Car Buyers Rushing to Beat Tariffs Find It's Tougher to Get Financing", 
     "The Future of Gadgets: Fewer Updates, More Subscriptions, Bigger Price Tags"

3. **Government AI Implementation**
   - Mentions across sources: 7
   - Key sources: Wired, AI News
   - Representative headlines: "DOGE Is in Its AI Era", "DOGE Put a College Student
     in Charge of Using AI to Rewrite Regulations", "A DOGE Recruiter Is Staffing a
     Project to Deploy AI Agents Across the US Government"

4. **AI Safety and Regulation Concerns**
   - Mentions across sources: 9
   - Key sources: TechCrunch, WSJ Tech, Wired
   - Representative headlines: "One of Google's recent Gemini AI models scores worse on 
     safety", "AI chatbots are 'juicing engagement' instead of being useful", "Dozens
     of YouTube Channels Are Showing AI-Generated Cartoon Gore and Fetish Content"

...

```


Try it for yourself! Install [Amazon Q CLI](https://docs.aws.amazon.com/amazonq/latest/qdeveloper-ug/command-line-installing.html) and play with the code here: [news-agents](https://github.com/eugeneyan/news-agents).

```
git clone https://github.com/eugeneyan/news-agents.git

cd news-agents
uv sync  # Sync dependencies
uv tree  # Check httpx and mcp[cli] are installed

q chat --trust-all-tools  # Start Q

/context add --global context/agents.md  # Add system context for multi-agents

Q, read context/main-agent.md and spin up sub agents to execute it.  # Start main agent

```


• • •

Initially, I wanted to host this as a web app, perhaps on a platform like [Daytona](https://www.daytona.io/). However, I quickly learned that building remote MCPs isn't trivial, especially with only a couple of weekend hours to hack on this. For now, I'll explore applying this setup to other use cases such as parsing design docs and [COEs](https://aws.amazon.com/blogs/mt/why-you-should-develop-a-correction-of-error-coe/), or multi-agent writing and coding workflows. If you're also experimenting with MCPs or agentic workflows, I'd love to [hear from you](https://x.com/eugeneyan)!

---

## Attribution and Open Source Spirit

This project is a great example of the value of open source: by forking and experimenting with Eugene Yan's work, I was able to learn about agentic workflows, MCP, and multi-agent coordination. All design, architecture, and original code are by Eugene Yan—my contribution is simply as a curious user, experimenter, and documenter of the setup and discovery process.

If you're interested in agentic workflows, I highly recommend checking out Eugene's original repo and blog. And if you're also learning by forking and tinkering, I'd love to hear from you!

# The Case of the Silent Tools: An Amazon Q MCP Debugging Saga

## Introduction: When Your Agent's Tools Go Missing

Integrating custom Python tools with an AI assistant like Amazon Q can be incredibly powerful. But what happens when your carefully crafted tools, designed to fetch the latest news, simply refuse to show up? This is a story of a multi-layered debugging adventure, from Python's import intricacies to the crucial, yet initially overlooked, configuration files that bridge your code to Amazon Q.

## The Initial Goal: Equipping Our Agent with News Superpowers

Our mission was to get the `news-mcp` server, defined in `src/main.py`, to provide its news-fetching capabilities as tools within an Amazon Q chat session. This server, using the Model Context Protocol (MCP), was designed to connect to various RSS feeds and return formatted stories. The expectation was that Amazon Q, via its command-line interface, would seamlessly pick up these tools.

## Roadblock #1: Python's Own `ModuleNotFoundError`

Before even getting to Amazon Q, we hit a snag trying to run our MCP server script directly. We navigated to the project root and executed:

```bash
cd /workspaces/news-agents
.venv/bin/python -m src.main
```

Instead of the expected "Server started..." message, Python complained loudly:

```
Traceback (most recent call last):
  File "<frozen runpy>", line 198, in _run_module_as_main
  File "<frozen runpy>", line 88, in _run_code
  File "/workspaces/news-agents/src/main.py", line 3, in <module>
    from ainews import (
ModuleNotFoundError: No module named 'ainews'
```

The `src/main.py` file had imports like `from ainews import ...`, `from hackernews import ...`, etc. While these modules (`ainews.py`, `hackernews.py`) were indeed present in the `src` directory alongside `main.py`, running `python -m src.main` from the parent directory (`/workspaces/news-agents/`) meant Python was looking for `ainews` as a top-level module, not as part of the `src` package.

**The Fix (Code Change): Embracing Relative Imports**

The solution was to adjust the import statements within `src/main.py` to be relative to the `src` package, as we were executing it as a module within that package context.

Original imports:
```python
from ainews import (...)
from hackernews import (...)
# ... and so on
```

Corrected relative imports:
```python
from .ainews import (...)
from .hackernews import (...)
# ... and so on
```

With this change, running `.venv/bin/python -m src.main` from the `/workspaces/news-agents` directory now worked! The server started, printing "Server started. Listening for requests...". A small victory, but the battle wasn't over.

## Roadblock #2: Amazon Q's Continued Silence

Despite `src/main.py` now running correctly on its own (implying it would communicate over `stdio`, which is what Amazon Q CLI expects by default), Amazon Q still couldn't see or initialize our news tools. When attempting to start a chat session:

```bash
q chat --trust-all-tools
```

We were met with a disheartening message:
```
✗ news_tools has failed to load:
- Operation timed out: recv for initialize
- run with Q_LOG_LEVEL=trace and see $TMPDIR/qlog for detail
✗ 0 of 1 mcp servers initialized
```
Clearly, just having a runnable Python script wasn't enough for Amazon Q to automatically discover and integrate the MCP server.

## The Investigation: Peeling Back the Layers of Integration

We enabled trace logging (`Q_LOG_LEVEL=trace q chat --trust-all-tools`) and pored over the logs. The logs confirmed Amazon Q was attempting *something* but failing to establish a proper handshake with our MCP server. This hinted that Amazon Q didn't know *how* to correctly start or communicate with our `src/main.py` script as an MCP server.

## The "Aha!" Moment: The Unseen Conductor - `.amazonq/mcp.json`

After consulting the Amazon Q Developer Guide, the missing piece became apparent: the `.amazonq/mcp.json` configuration file. This file is crucial for telling the Amazon Q CLI how to discover, launch, and manage local MCP servers. Our project was missing it entirely!

Without this file, Amazon Q had no explicit instructions on how to run our Python script as the "news-tools" MCP server it was expecting (perhaps based on a previous, now-failed, attempt or a default assumption).

## The Fix (Configuration): Crafting the `mcp.json` Bridge

We created the `.amazonq/mcp.json` file in the root of our workspace (`/workspaces/news-agents`) with the following configuration:

```json
{
  "mcpServers": {
    "news-tools": {
      "command": "/workspaces/news-agents/.venv/bin/python",
      "args": ["-m", "src.main"],
      "env": {
        "PYTHONPATH": "/workspaces/news-agents"
      }
    }
  }
}
```

Let's break this down:
-   `"mcpServers"`: The main object defining all local MCP servers.
-   `"news-tools"`: A unique name for our server, matching what Amazon Q might be expecting or what we'd like to call it.
-   `"command"`: The exact path to the Python interpreter within our project's virtual environment. This ensures the correct dependencies are used.
-   `"args"`: The arguments to pass to the Python interpreter. `["-m", "src.main"]` tells Python to run the `main.py` script located within the `src` directory as a module. This aligns with how we fixed the `ModuleNotFoundError` earlier.
-   `"env"`: Environment variables to set for the server process.
    -   `"PYTHONPATH": "/workspaces/news-agents"`: This is important. Even though we're running `src.main` as a module, setting `PYTHONPATH` to the project root ensures that Python can correctly resolve the `src` package and its internal relative imports from the perspective of the `command` being executed.

## Sweet Success: Tools Online!

With the corrected relative imports in `src/main.py` AND the crucial `.amazonq/mcp.json` file in place, we tried again:

```bash
q chat --trust-all-tools
```

And this time... success! Amazon Q reported that the `news-tools` MCP server was initialized, and our custom news fetching tools were finally available in the chat session.

## Lessons Learned from the Debugging Trenches

This journey from a `ModuleNotFoundError` to a fully integrated set of Amazon Q tools taught us several valuable lessons:

1.  **Python Imports and Execution Context:** How you run your Python script (e.g., `python script.py` vs. `python -m package.module`) deeply affects how imports are resolved. Relative imports (`from .module`) are key when creating runnable packages/modules.
2.  **Configuration is King (for Integration):** For tools like Amazon Q CLI to integrate with external processes like your MCP server, they often rely on explicit configuration files (`.amazonq/mcp.json` in this case). These files bridge the gap between the tool and your code.
3.  **The Importance of `PYTHONPATH` (Sometimes):** While relative imports solve many issues within a package, `PYTHONPATH` can still be necessary in configuration files like `mcp.json` to ensure the interpreter launched by the external tool (Amazon Q) can find your top-level package directory.
4.  **Layered Debugging:** Often, fixing one error (like the `ModuleNotFoundError`) simply allows you to proceed to the next layer of the problem (like the tool integration failure).
5.  **RTFM (Read The Fine Manual):** When integrating with complex tools, the official documentation is your best friend. The purpose and schema of `mcp.json` were waiting to be discovered there.
6.  **Understanding the Toolchain:** Knowing that Amazon Q CLI typically uses `stdio` for MCP communication by default helped us focus on command-line execution and configuration rather than network ports (which was an earlier, incorrect assumption).

## Conclusion: Every Bug Fix is a Step Forward

What began as a frustrating series of errors—first in Python, then in Amazon Q—transformed into a valuable learning experience. Successfully integrating custom tools requires understanding not just your own code, but also how the external systems discover, launch, and communicate with it. The silent tools finally found their voice, all thanks to a corrected import and a small but mighty JSON configuration file.

---

*This post reflects a real debugging journey encountered while working with Python, the Model Context Protocol, and Amazon Q.*
