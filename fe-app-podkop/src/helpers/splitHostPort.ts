// Splits a "host:port" part of a URL, supporting bracketed IPv6 literals
// like "[2001:db8::1]:443"; the host is returned without brackets
export function splitHostPort(hostPort: string): {
  host: string;
  port: string | undefined;
} {
  if (hostPort.startsWith('[')) {
    const closingIndex = hostPort.indexOf(']');
    if (closingIndex === -1) {
      return { host: '', port: undefined };
    }

    const host = hostPort.slice(1, closingIndex);
    const rest = hostPort.slice(closingIndex + 1);
    const port = rest.startsWith(':') ? rest.slice(1) : undefined;

    return { host, port };
  }

  const separatorIndex = hostPort.indexOf(':');
  if (separatorIndex === -1) {
    return { host: hostPort, port: undefined };
  }

  return {
    host: hostPort.slice(0, separatorIndex),
    port: hostPort.slice(separatorIndex + 1),
  };
}
