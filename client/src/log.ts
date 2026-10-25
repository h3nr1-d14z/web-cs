type Sink = (line: string) => void

const MAX_LINES = 600

/**
 * Tiny fan-out logger: engine stdout, transport events and boot progress all
 * end up in the same place so `?debug=1` (or the "Nhật ký" button) shows one
 * continuous timeline — which is what you want when a client fails to connect.
 */
class Logger {
  readonly lines: string[] = []
  private sinks = new Set<Sink>()

  push(scope: string, message: string): void {
    const line = `[${scope}] ${message}`
    this.lines.push(line)
    if (this.lines.length > MAX_LINES) this.lines.splice(0, this.lines.length - MAX_LINES)
    for (const sink of this.sinks) sink(line)
  }

  subscribe(sink: Sink): () => void {
    this.sinks.add(sink)
    return () => this.sinks.delete(sink)
  }
}

export const log = new Logger()
