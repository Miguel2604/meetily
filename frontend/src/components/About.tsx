import React, { useState, useEffect } from "react";
import { getVersion } from '@tauri-apps/api/app';
import AnalyticsConsentSwitch from "./AnalyticsConsentSwitch";
import { UpdateDialog } from "./UpdateDialog";
import { updateService, UpdateInfo } from '@/services/updateService';
import { Button } from './ui/button';
import { Loader2 } from 'lucide-react';
import { toast } from 'sonner';
import { MeetyMark } from './MeetyMark';

const FACTS = [
    ['Stays on this computer', 'Audio, transcripts and summaries are stored and processed locally. Nothing is uploaded unless you pick a cloud model.'],
    ['Any model you like', 'Run the built-in or an Ollama model, or connect your own API key. No lock-in.'],
    ['No per-minute bill', 'Local transcription and summaries cost nothing to run.'],
    ['Works with every call app', 'Zoom, Google Meet, Teams or a room with no call at all.'],
];

export function About() {
    const [currentVersion, setCurrentVersion] = useState<string>('0.4.1');
    const [updateInfo, setUpdateInfo] = useState<UpdateInfo | null>(null);
    const [isChecking, setIsChecking] = useState(false);
    const [showUpdateDialog, setShowUpdateDialog] = useState(false);

    useEffect(() => {
        getVersion().then(setCurrentVersion).catch(console.error);
    }, []);

    const handleCheckForUpdates = async () => {
        setIsChecking(true);
        try {
            const info = await updateService.checkForUpdates(true);
            setUpdateInfo(info);
            if (info.available) {
                setShowUpdateDialog(true);
            } else {
                toast.success('You are running the latest version');
            }
        } catch (error: any) {
            console.error('Failed to check for updates:', error);
            toast.error('Failed to check for updates: ' + (error.message || 'Unknown error'));
        } finally {
            setIsChecking(false);
        }
    };

    return (
        <div className="space-y-6 max-h-[80vh] overflow-y-auto">
            <div className="flex items-center gap-3">
                <MeetyMark size={44} />
                <div className="flex-1">
                    <h2 className="text-xl font-semibold tracking-[-0.01em] text-gray-950">Meety</h2>
                    <p className="text-sm text-gray-600 tabular-nums">
                        Version {currentVersion}
                        {updateInfo?.available && <> · v{updateInfo.version} available</>}
                    </p>
                </div>
                <Button onClick={handleCheckForUpdates} disabled={isChecking} variant="outline" size="sm">
                    {isChecking && <Loader2 className="h-3.5 w-3.5 mr-2 animate-spin" />}
                    {isChecking ? 'Checking…' : 'Check for updates'}
                </Button>
            </div>

            <p className="text-[15px] leading-relaxed text-gray-900">
                Meety records your meetings, transcribes them and writes the notes, all on this computer.
            </p>

            <dl className="grid grid-cols-2 gap-x-6 gap-y-4">
                {FACTS.map(([title, text]) => (
                    <div key={title}>
                        <dt className="text-sm font-medium text-gray-950">{title}</dt>
                        <dd className="mt-1 text-sm leading-relaxed text-gray-600">{text}</dd>
                    </div>
                ))}
            </dl>

            <AnalyticsConsentSwitch />

            <UpdateDialog
                open={showUpdateDialog}
                onOpenChange={setShowUpdateDialog}
                updateInfo={updateInfo}
            />
        </div>
    )
}
