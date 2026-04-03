import { useState, useCallback, useRef, useEffect } from "react";
import type { PayloadType, BenchmarkResult } from "@/lib/types";
import { ALL_PAYLOADS, PAYLOAD_LABELS, PAYLOAD_SIZES } from "@/lib/types";
import type { WorkerMessage } from "@/lib/ts-worker";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Progress } from "@/components/ui/progress";
import { Separator } from "@/components/ui/separator";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

import TsWorker from "@/lib/ts-worker?worker";
import WasmWorker from "@/lib/wasm-worker?worker";

function formatOps(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return n.toFixed(0);
}

function formatNs(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)} ms`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)} us`;
  return `${n.toFixed(1)} ns`;
}

function formatMBs(n: number): string {
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)} GB/s`;
  return `${n.toFixed(1)} MB/s`;
}

function formatSpeedup(n: number): string {
  return n >= 10 ? `${n.toFixed(0)}x` : `${n.toFixed(1)}x`;
}

const ITERATIONS = 100_000;

const SIZE_DATA = [
  { label: "bcs-zig (WASM)", kb: 12.6, color: "bg-cyan-500", note: "wasm32-freestanding" },
  { label: "@mysten/bcs (JS)", kb: 10, color: "bg-amber-500", note: "minified + gzip" },
];

export function App() {
  const [running, setRunning] = useState(false);
  const [tsDone, setTsDone] = useState(false);
  const [wasmDone, setWasmDone] = useState(false);
  const [showResults, setShowResults] = useState(false);
  const [tsResults, setTsResults] = useState<Map<PayloadType, BenchmarkResult>>(new Map());
  const [wasmResults, setWasmResults] = useState<Map<PayloadType, BenchmarkResult>>(new Map());
  const tsWorkerRef = useRef<Worker | null>(null);
  const wasmWorkerRef = useRef<Worker | null>(null);

  const runBenchmarks = useCallback(() => {
    setRunning(true);
    setTsDone(false);
    setWasmDone(false);
    setShowResults(false);
    setTsResults(new Map());
    setWasmResults(new Map());

    tsWorkerRef.current?.terminate();
    wasmWorkerRef.current?.terminate();

    const tsWorker = new TsWorker();
    const wasmWorker = new WasmWorker();
    tsWorkerRef.current = tsWorker;
    wasmWorkerRef.current = wasmWorker;

    let tsFinished = false;
    let wasmFinished = false;

    const checkDone = () => {
      if (tsFinished && wasmFinished) setRunning(false);
    };

    tsWorker.onmessage = (e: MessageEvent<WorkerMessage>) => {
      const msg = e.data;
      if (msg.type === "result") {
        setTsResults((prev) => new Map(prev).set(msg.result.payload, msg.result));
      } else if (msg.type === "done") {
        tsFinished = true;
        setTsDone(true);
        tsWorker.terminate();
        checkDone();
      }
    };

    wasmWorker.onmessage = (e: MessageEvent<WorkerMessage>) => {
      const msg = e.data;
      if (msg.type === "result") {
        setWasmResults((prev) => new Map(prev).set(msg.result.payload, msg.result));
      } else if (msg.type === "done") {
        wasmFinished = true;
        setWasmDone(true);
        wasmWorker.terminate();
        checkDone();
      }
    };

    tsWorker.postMessage({ type: "start", iterations: ITERATIONS });
    wasmWorker.postMessage({ type: "start", iterations: ITERATIONS });
  }, []);

  // Show results modal when both finish
  const bothDone = tsDone && wasmDone;
  useEffect(() => {
    if (bothDone) setShowResults(true);
  }, [bothDone]);

  const tsCount = tsResults.size;
  const wasmCount = wasmResults.size;
  const totalPayloads = ALL_PAYLOADS.length;

  const speedups: { payload: PayloadType; ratio: number }[] = [];
  for (const payload of ALL_PAYLOADS) {
    const ts = tsResults.get(payload);
    const wasm = wasmResults.get(payload);
    if (ts && wasm) {
      speedups.push({ payload, ratio: wasm.opsPerSec / ts.opsPerSec });
    }
  }

  const avgSpeedup =
    speedups.length > 0
      ? speedups.reduce((s, x) => s + x.ratio, 0) / speedups.length
      : 0;

  return (
    <div className="min-h-screen bg-background p-6 md:p-10">
      <div className="mx-auto max-w-6xl space-y-8">
        {/* Header */}
        <div className="space-y-2 text-center">
          <h1 className="text-4xl font-bold tracking-tight">
            BCS Benchmark
          </h1>
          <p className="text-muted-foreground">
            Binary Canonical Serialization — @mysten/bcs (TypeScript) vs bcs-zig (WASM)
          </p>
        </div>

        {/* Controls */}
        <div className="flex flex-col items-center gap-3">
          <Button className="h-14 px-12 text-lg" onClick={runBenchmarks} disabled={running}>
            {running ? "Running..." : "Run Benchmark"}
          </Button>
          <p className="text-xs text-muted-foreground font-mono">100,000 iterations per payload</p>
        </div>

        {/* Results Tables */}
        <div className="grid gap-6 lg:grid-cols-2">
          {/* TypeScript Panel */}
          <Card>
            <CardHeader>
              <div className="flex items-center gap-3">
                <Badge variant="outline" className="border-amber-500/50 text-amber-500">
                  TS
                </Badge>
                <div>
                  <CardTitle>@mysten/bcs</CardTitle>
                  <CardDescription>TypeScript — pure JavaScript</CardDescription>
                </div>
                {running && !tsDone && (
                  <span className="ml-auto text-xs text-muted-foreground animate-pulse">{tsCount}/{totalPayloads}</span>
                )}
                {tsDone && (
                  <span className="ml-auto text-xs text-muted-foreground">done</span>
                )}
              </div>
              {running && !tsDone && (
                <Progress value={(tsCount / totalPayloads) * 100} className="h-1.5 mt-2" />
              )}
            </CardHeader>
            <CardContent>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Payload</TableHead>
                    <TableHead className="text-right">ops/s</TableHead>
                    <TableHead className="text-right">Latency</TableHead>
                    <TableHead className="text-right">Throughput</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {ALL_PAYLOADS.map((payload) => {
                    const r = tsResults.get(payload);
                    return (
                      <TableRow key={payload}>
                        <TableCell className="font-mono text-xs">
                          {PAYLOAD_LABELS[payload]}
                          <span className="ml-1 text-muted-foreground">
                            ({PAYLOAD_SIZES[payload]}B)
                          </span>
                        </TableCell>
                        <TableCell className="text-right font-mono font-semibold">
                          {r ? formatOps(r.opsPerSec) : "—"}
                        </TableCell>
                        <TableCell className="text-right font-mono text-muted-foreground">
                          {r ? formatNs(r.nsPerOp) : "—"}
                        </TableCell>
                        <TableCell className="text-right font-mono text-muted-foreground">
                          {r ? formatMBs(r.throughputMBs) : "—"}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </CardContent>
          </Card>

          {/* Zig WASM Panel */}
          <Card>
            <CardHeader>
              <div className="flex items-center gap-3">
                <Badge variant="outline" className="border-cyan-500/50 text-cyan-500">
                  WASM
                </Badge>
                <div>
                  <CardTitle>bcs-zig</CardTitle>
                  <CardDescription>Zig compiled to WASM</CardDescription>
                </div>
                {running && !wasmDone && (
                  <span className="ml-auto text-xs text-muted-foreground animate-pulse">{wasmCount}/{totalPayloads}</span>
                )}
                {wasmDone && (
                  <span className="ml-auto text-xs text-muted-foreground">done</span>
                )}
              </div>
              {running && !wasmDone && (
                <Progress value={(wasmCount / totalPayloads) * 100} className="h-1.5 mt-2" />
              )}
            </CardHeader>
            <CardContent>
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead>Payload</TableHead>
                    <TableHead className="text-right">ops/s</TableHead>
                    <TableHead className="text-right">Latency</TableHead>
                    <TableHead className="text-right">Throughput</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {ALL_PAYLOADS.map((payload) => {
                    const r = wasmResults.get(payload);
                    return (
                      <TableRow key={payload}>
                        <TableCell className="font-mono text-xs">
                          {PAYLOAD_LABELS[payload]}
                          <span className="ml-1 text-muted-foreground">
                            ({PAYLOAD_SIZES[payload]}B)
                          </span>
                        </TableCell>
                        <TableCell className="text-right font-mono font-semibold">
                          {r ? formatOps(r.opsPerSec) : "—"}
                        </TableCell>
                        <TableCell className="text-right font-mono text-muted-foreground">
                          {r ? formatNs(r.nsPerOp) : "—"}
                        </TableCell>
                        <TableCell className="text-right font-mono text-muted-foreground">
                          {r ? formatMBs(r.throughputMBs) : "—"}
                        </TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            </CardContent>
          </Card>
        </div>

        {/* Binary Size Comparison */}
        <Card>
          <CardHeader>
            <CardTitle>Binary / Bundle Size</CardTitle>
            <CardDescription>
              WASM binary vs JS bundle — smaller is faster to load
            </CardDescription>
          </CardHeader>
          <CardContent className="space-y-4">
            {SIZE_DATA.map((s) => (
              <div key={s.label} className="flex items-center gap-4">
                <span className="w-40 shrink-0 font-medium">{s.label}</span>
                <div className="relative flex-1 h-7 rounded-md bg-muted/40 overflow-hidden">
                  <div
                    className={`h-full rounded-md ${s.color} flex items-center px-3 transition-all duration-700`}
                    style={{ width: `${(s.kb / 15) * 100}%` }}
                  >
                    <span className="font-mono text-xs font-bold text-white drop-shadow-sm">
                      {s.kb} KB
                    </span>
                  </div>
                </div>
                <span className="w-52 shrink-0 text-right text-xs text-muted-foreground">
                  {s.note}
                </span>
              </div>
            ))}
          </CardContent>
        </Card>

        <Separator />

        {/* Footer */}
        <div className="flex items-center justify-between text-xs text-muted-foreground font-mono">
          <span>&copy; Unconfirmed Labs, LLC</span>
          <a href="https://github.com/unconfirmedlabs/bcs-zig" target="_blank" rel="noopener noreferrer" className="hover:text-foreground transition-colors">
            GitHub
          </a>
        </div>
      </div>

      {/* Results Modal */}
      <Dialog open={showResults} onOpenChange={setShowResults}>
        <DialogContent className="sm:max-w-[90vw] lg:max-w-5xl">
          <DialogHeader className="text-center">
            <DialogTitle className="text-2xl pr-6">
              Zig WASM is{" "}
              <span className="text-emerald-500">{formatSpeedup(avgSpeedup)}</span>
              {" "}faster on average
            </DialogTitle>
            <DialogDescription>
              Serialize + deserialize roundtrip across {ALL_PAYLOADS.length} payload types — 100K iterations each
            </DialogDescription>
          </DialogHeader>
          <div className="grid grid-cols-5 gap-3 pt-2">
            {speedups.map(({ payload, ratio }) => (
              <div
                key={payload}
                className="rounded-lg border bg-card p-4 text-center"
              >
                <p className="mb-1 text-xs font-medium text-muted-foreground whitespace-nowrap">
                  {PAYLOAD_LABELS[payload]}
                </p>
                <p
                  className={`font-mono text-xl font-bold ${
                    ratio > 1.1
                      ? "text-emerald-500"
                      : ratio < 0.9
                        ? "text-red-500"
                        : "text-muted-foreground"
                  }`}
                >
                  {formatSpeedup(ratio)}
                  <span className="text-xs font-normal opacity-60"> faster</span>
                </p>
              </div>
            ))}
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export default App;
