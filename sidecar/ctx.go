package main

import "context"

type tokenKey struct{}

func withToken(ctx context.Context, t string) context.Context {
	return context.WithValue(ctx, tokenKey{}, t)
}
