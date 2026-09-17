import { describe, it, expect } from 'vitest';
import { splitHostPort } from '../splitHostPort';

describe('splitHostPort', () => {
  it('splits a domain with port', () => {
    expect(splitHostPort('example.com:443')).toEqual({
      host: 'example.com',
      port: '443',
    });
  });

  it('splits an IPv4 with port', () => {
    expect(splitHostPort('127.0.0.1:1080')).toEqual({
      host: '127.0.0.1',
      port: '1080',
    });
  });

  it('returns no port for a bare domain', () => {
    expect(splitHostPort('example.com')).toEqual({
      host: 'example.com',
      port: undefined,
    });
  });

  it('splits a bracketed IPv6 with port', () => {
    expect(splitHostPort('[2001:db8::1]:443')).toEqual({
      host: '2001:db8::1',
      port: '443',
    });
  });

  it('returns no port for a bracketed IPv6 without port', () => {
    expect(splitHostPort('[2001:db8::1]')).toEqual({
      host: '2001:db8::1',
      port: undefined,
    });
  });

  it('returns empty host for an unclosed bracket', () => {
    expect(splitHostPort('[2001:db8::1:443')).toEqual({
      host: '',
      port: undefined,
    });
  });
});
