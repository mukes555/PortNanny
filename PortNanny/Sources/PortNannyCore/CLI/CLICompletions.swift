import Foundation

/// Static shell completions: the command set is small enough to spell out.
/// `portnanny completions zsh > ~/.zfunc/_portnanny` (or let the cask do it).
public enum CLICompletions {
    public static let commands = ["list", "kill", "free", "wait", "open", "history", "whois", "whoami", "agents", "reserve", "release", "reservations", "exec", "drift", "free-port", "schema", "doctor", "setup", "agent-docs", "mcp", "completions", "version", "help"]

    public static func script(for shell: String) -> String? {
        switch shell {
        case "zsh": return zsh
        case "bash": return bash
        case "fish": return fish
        default: return nil
        }
    }

    private static let zsh = """
    #compdef portnanny
    local -a commands
    commands=(
      'list:list listening ports (with owning agent)'
      'kill:kill everything on a port'
      'free:kill, exit 0 if already free'
      'wait:block until a port is free'
      'open:open localhost:<port> in the browser'
      'history:recent kills, who started and who stopped them'
      'whois:who started what is on a port, and why PortNanny thinks so'
      'whoami:how the friendly-fire guard identifies you'
      'reserve:lease a free port for a while'
      'release:give a lease back'
      'reservations:live leases'
      'exec:run a command with PORT set to a free, leased port'
      'drift:servers not on the port their project configured'
      'free-port:first free port in a range'
      'schema:JSON output contracts'
      'doctor:environment and scanner diagnostics'
      'setup:set the AI tools on this Mac up'
      'agent-docs:snippet for CLAUDE.md / AGENTS.md'
      'completions:shell completion script'
      'version:print version'
      'help:usage'
    )
    if (( CURRENT == 2 )); then
      _describe 'command' commands
      return
    fi
    case $words[2] in
      list) _arguments '--json' '--mine' '--unowned' '--orphaned' '--agent[agent name]:name' ;;
      kill|free) _arguments '--force' '-9' '--dry-run' '--json' '--orphaned' '--pid[process id]:pid' ;;
      wait) _arguments '--json' '--timeout[seconds]:seconds' ;;
      free-port) _arguments '--json' '--prefer[port]:port' '--range[A-B]:range' ;;
      schema) _values 'command' list kill whois whoami wait history version doctor agents free-port reserve release reservations drift ;;
      history) _arguments '--json' '--all' '--port[port]:port' '--limit[count]:count' ;;
      whois) _arguments '--json' '--pid[process id]:pid' ;;
      reserve) _arguments '--json' '--for[duration, e.g. 10m]:duration' '--reason[why]:reason' ;;
      release) _arguments '--json' '--force' ;;
      reservations|drift) _arguments '--json' ;;
      exec) _arguments '--port[port]:port' '--free-port' '--prefer[port]:port' '--range[A-B]:range' '--no-reserve' '--owner[name]:name' '--session[key]:key' ;;
      doctor) _arguments '--json' '--agents' ;;
      setup) _arguments '--yes' '--project[directory]:directory:_files -/' ;;
      agent-docs) _arguments '--write' '--file[path]:file:_files' '--claude' '--codex' '--cursor' '--windsurf' '--claude-hook' ;;
      whoami|version) _arguments '--json' ;;
      mcp) _arguments '--setup[registration for an agent]:agent:(claude cursor codex)' ;;
      completions) _values 'shell' zsh bash fish ;;
    esac
    """

    private static let bash = """
    _portnanny() {
      local cur="${COMP_WORDS[COMP_CWORD]}"
      if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "\(commands.joined(separator: " "))" -- "$cur") )
        return
      fi
      case "${COMP_WORDS[1]}" in
        list) COMPREPLY=( $(compgen -W "--json --mine --unowned --orphaned --agent" -- "$cur") ) ;;
        kill|free) COMPREPLY=( $(compgen -W "--force -9 --dry-run --json --orphaned --pid" -- "$cur") ) ;;
        wait) COMPREPLY=( $(compgen -W "--json --timeout" -- "$cur") ) ;;
        free-port) COMPREPLY=( $(compgen -W "--json --prefer --range" -- "$cur") ) ;;
        schema) COMPREPLY=( $(compgen -W "list kill whois whoami wait history version doctor agents free-port reserve release reservations drift" -- "$cur") ) ;;
        history) COMPREPLY=( $(compgen -W "--json --all --port --limit" -- "$cur") ) ;;
        whois) COMPREPLY=( $(compgen -W "--json --pid" -- "$cur") ) ;;
        reserve) COMPREPLY=( $(compgen -W "--json --for --reason" -- "$cur") ) ;;
        release) COMPREPLY=( $(compgen -W "--json --force" -- "$cur") ) ;;
        reservations|drift) COMPREPLY=( $(compgen -W "--json" -- "$cur") ) ;;
        exec) COMPREPLY=( $(compgen -W "--port --free-port --prefer --range --no-reserve --owner --session" -- "$cur") ) ;;
        doctor) COMPREPLY=( $(compgen -W "--json --agents" -- "$cur") ) ;;
        setup) COMPREPLY=( $(compgen -W "--yes --project" -- "$cur") ) ;;
        agent-docs) COMPREPLY=( $(compgen -W "--write --file --claude --codex --cursor --windsurf --claude-hook" -- "$cur") ) ;;
        whoami|version) COMPREPLY=( $(compgen -W "--json" -- "$cur") ) ;;
        mcp) COMPREPLY=( $(compgen -W "--setup claude cursor codex" -- "$cur") ) ;;
        completions) COMPREPLY=( $(compgen -W "zsh bash fish" -- "$cur") ) ;;
      esac
    }
    complete -F _portnanny portnanny
    """

    private static let fish = """
    complete -c portnanny -f
    \(commands.map { "complete -c portnanny -n '__fish_use_subcommand' -a \($0)" }.joined(separator: "\n"))
    complete -c portnanny -n '__fish_seen_subcommand_from list' -l json -l mine -l unowned -l orphaned -l agent
    complete -c portnanny -n '__fish_seen_subcommand_from kill free' -l force -l dry-run -l json -l orphaned -l pid
    complete -c portnanny -n '__fish_seen_subcommand_from wait' -l json -l timeout
    complete -c portnanny -n '__fish_seen_subcommand_from free-port' -l json -l prefer -l range
    complete -c portnanny -n '__fish_seen_subcommand_from schema' -a 'list kill whois whoami wait history version doctor agents free-port reserve release reservations drift'
    complete -c portnanny -n '__fish_seen_subcommand_from history' -l json -l all -l port -l limit
    complete -c portnanny -n '__fish_seen_subcommand_from whois' -l json -l pid
    complete -c portnanny -n '__fish_seen_subcommand_from reserve' -l json -l for -l reason
    complete -c portnanny -n '__fish_seen_subcommand_from release' -l json -l force
    complete -c portnanny -n '__fish_seen_subcommand_from reservations drift' -l json
    complete -c portnanny -n '__fish_seen_subcommand_from exec' -l port -l free-port -l prefer -l range -l no-reserve -l owner -l session
    complete -c portnanny -n '__fish_seen_subcommand_from doctor' -l json -l agents
    complete -c portnanny -n '__fish_seen_subcommand_from setup' -l yes -l project
    complete -c portnanny -n '__fish_seen_subcommand_from agent-docs' -l write -l file -l claude -l codex -l cursor -l windsurf -l claude-hook
    complete -c portnanny -n '__fish_seen_subcommand_from whoami version' -l json
    complete -c portnanny -n '__fish_seen_subcommand_from mcp' -l setup -a 'claude cursor codex'
    complete -c portnanny -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish'
    """
}
