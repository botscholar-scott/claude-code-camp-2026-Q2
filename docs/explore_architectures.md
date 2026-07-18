# Explore Agent Architectures

The largest confusion tech professionals have is applying the correct agent solution because many solutions appear to overlap responsibilities.

We will explore multiple agent architectures to determine fit for our agent workload.

## 1. An agent file with referenced files e.g. Agent.md, @~/docs/*.md

The simplest agent was creating an "agent file" and possibly importing other files that are read conditionally when needed.

We should attempt to create an agent file and see if it can connect to the MUD and complete a simple goal:
"Find the bakery and list the menu."

We want to use the smallest and least intelligent model and scale up from there.

### Technical Observations

Using Haiku 4.5 we created a CLAUDE.md with a simple prompt and told it will need to manage its own local memory through simple markdown files in the data folder. We noted the host information and port for connecting to the MUD as well as player credentials.

The agent really struggled to connect to the MUD.
The agent would attempt to create temporary shell and python scripts to manage the connection and execute commands.
The agent did not have enought information about the text user interface of the MUD to login and see its mistakes.
The agent would try and read files not related to its provided goal (e.g. infrastructure/ or game data files).
Increasing the model to Sonnet 5 did not help.

### Technical Conclusions
We could probvably write a better prompt or create an arti9fact that would give the agent full knowledge of the MUD's text user interface to successfully login, but since this experience is so fixed, it would be better to have a script that exactly knows how to login so we are not wasting token/usage and provides more deterministic user flows.

Coding harnesses tend to go off task and try to write code which we do not need our agent to do.
Coding harnesses at least at this specific architecture stage do not seem to be a good fit for this problem.

We are justified to build our own MUD SDK to connect to the MUD since clearly the agent wants to manage the connection through a script and execute commands over this connection.

If we had an MCP server with our MUD SDK perhaps we could drive the agent better at this architectural level.

Based on the complexity of the world and player state data updating markdown files will not be a sufficient and scalable way to capture this but we never concluded whether the current agentic loop of the coding harness could complete the initial goal.

> Use coding harness for coding, and for specialized agents make y our own loop.
