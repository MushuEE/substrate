//  Copyright 2026 Google LLC
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.

package store_test

import (
	"context"
	"testing"

	"github.com/agent-substrate/substrate/cmd/servers/ateapi/store/ateredis"
	"github.com/agent-substrate/substrate/proto/ateapipb"
	"github.com/alicebob/miniredis/v2"
	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

// BenchmarkCreateActor_Valkey measures the raw in-memory write latency
// of creating an actor using the Valkey speed layer.
func BenchmarkCreateActor_Valkey(b *testing.B) {
	mr, err := miniredis.Run()
	if err != nil {
		b.Fatalf("failed to start miniredis: %v", err)
	}
	defer mr.Close()

	rdb := redis.NewClusterClient(&redis.ClusterOptions{
		Addrs: []string{mr.Addr()},
	})
	s := ateredis.NewPersistence(rdb)
	ctx := context.Background()

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		actorID := uuid.NewString()
		actor := &ateapipb.Actor{
			ActorId:                actorID,
			ActorTemplateNamespace: "default",
			ActorTemplateName:      "counter",
			Status:                 ateapipb.Actor_STATUS_SUSPENDED,
		}
		err := s.CreateActor(ctx, actor)
		if err != nil {
			b.Fatalf("CreateActor failed: %v", err)
		}
	}
}
