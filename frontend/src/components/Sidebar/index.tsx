'use client';

import React, { useState, useMemo, useEffect, useCallback } from 'react';
import { Settings, Home, Trash2, Pencil, NotebookPen, SearchIcon, X, Upload, PanelLeftClose, PanelLeftOpen } from 'lucide-react';
import { useRouter, usePathname } from 'next/navigation';
import { useSidebar } from './SidebarProvider';
import type { CurrentMeeting } from '@/components/Sidebar/SidebarProvider';
import { ConfirmationModal } from '../ConfirmationModel/confirmation-modal';
import { ModelConfig } from '@/components/ModelSettingsModal';
import { SettingTabs } from '../SettingTabs';
import { TranscriptModelProps } from '@/components/TranscriptSettings';
import Analytics from '@/lib/analytics';
import { invoke } from '@tauri-apps/api/core';
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip';
import { toast } from 'sonner';
import { useRecordingState } from '@/contexts/RecordingStateContext';
import { useImportDialog } from '@/contexts/ImportDialogContext';
import { useConfig } from '@/contexts/ConfigContext';

import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
} from "@/components/ui/dialog"
import { VisuallyHidden } from "@/components/ui/visually-hidden"

import { MessageToast } from '../MessageToast';
import Logo from '../Logo';
import Info from '../Info';
import { ComplianceNotification } from '../ComplianceNotification';
import { Input } from '../ui/input';
import { InputGroup, InputGroupAddon, InputGroupButton, InputGroupInput } from '../ui/input-group';
import { DEFAULT_PARAKEET_MODEL } from '@/constants/modelDefaults';

interface SidebarItem {
  id: string;
  title: string;
  type: 'folder' | 'file';
  children?: SidebarItem[];
}

const Sidebar: React.FC = () => {
  const router = useRouter();
  const pathname = usePathname();
  const {
    currentMeeting,
    setCurrentMeeting,
    sidebarItems,
    isCollapsed,
    toggleCollapse,
    handleRecordingToggle,
    searchTranscripts,
    searchResults,
    isSearching,
    meetings,
    setMeetings,
    serverAddress
  } = useSidebar();

  // Get recording state from RecordingStateContext (single source of truth)
  const { isRecording } = useRecordingState();
  const { openImportDialog } = useImportDialog();
  const { betaFeatures } = useConfig();
  const [expandedFolders, setExpandedFolders] = useState<Set<string>>(new Set(['meetings']));
  const [searchQuery, setSearchQuery] = useState<string>('');
  const [showModelSettings, setShowModelSettings] = useState(false);
  const [modelConfig, setModelConfig] = useState<ModelConfig>({
    provider: 'ollama',
    model: '',
    whisperModel: '',
    apiKey: null,
    ollamaEndpoint: null
  });
  const [transcriptModelConfig, setTranscriptModelConfig] = useState<TranscriptModelProps>({
    provider: 'parakeet',
    model: DEFAULT_PARAKEET_MODEL,
  });
  const [settingsSaveSuccess, setSettingsSaveSuccess] = useState<boolean | null>(null);

  // State for edit modal
  const [editModalState, setEditModalState] = useState<{ isOpen: boolean; meetingId: string | null; currentTitle: string }>({
    isOpen: false,
    meetingId: null,
    currentTitle: ''
  });
  const [editingTitle, setEditingTitle] = useState<string>('');

  // Ensure 'meetings' folder is always expanded
  useEffect(() => {
    if (!expandedFolders.has('meetings')) {
      const newExpanded = new Set(expandedFolders);
      newExpanded.add('meetings');
      setExpandedFolders(newExpanded);
    }
  }, [expandedFolders]);

  // useEffect(() => {
  //   if (settingsSaveSuccess !== null) {
  //     const timer = setTimeout(() => {
  //       setSettingsSaveSuccess(null);
  //     }, 3000);
  //   }
  // }, [settingsSaveSuccess]);


  const [deleteModalState, setDeleteModalState] = useState<{ isOpen: boolean; itemId: string | null }>({ isOpen: false, itemId: null });

  useEffect(() => {
    // Note: Don't set hardcoded defaults - let DB be the source of truth
    const fetchModelConfig = async () => {
      // Only make API call if serverAddress is loaded
      if (!serverAddress) {
        console.log('Waiting for server address to load before fetching model config');
        return;
      }

      try {
        const data = await invoke('api_get_model_config') as any;
        if (data && data.provider !== null) {
          // Fetch API key if not included and provider requires it
          if (data.provider !== 'ollama' && !data.apiKey) {
            try {
              const apiKeyData = await invoke('api_get_api_key', {
                provider: data.provider
              }) as string;
              data.apiKey = apiKeyData;
            } catch (err) {
              console.error('Failed to fetch API key:', err);
            }
          }
          setModelConfig(data);
        }
      } catch (error) {
        console.error('Failed to fetch model config:', error);
      }
    };

    fetchModelConfig();
  }, [serverAddress]);


  useEffect(() => {
    // Note: Don't set hardcoded defaults - let DB be the source of truth
    const fetchTranscriptSettings = async () => {
      // Only make API call if serverAddress is loaded
      if (!serverAddress) {
        console.log('Waiting for server address to load before fetching transcript settings');
        return;
      }

      try {
        const data = await invoke('api_get_transcript_config') as any;
        if (data && data.provider !== null) {
          setTranscriptModelConfig(data);
        }
      } catch (error) {
        console.error('Failed to fetch transcript settings:', error);
      }
    };
    fetchTranscriptSettings();
  }, [serverAddress]);

  // Listen for model config updates from other components
  useEffect(() => {
    const setupListener = async () => {
      const { listen } = await import('@tauri-apps/api/event');
      const unlisten = await listen<ModelConfig>('model-config-updated', (event) => {
        console.log('Sidebar received model-config-updated event:', event.payload);
        setModelConfig(event.payload);
      });

      return unlisten;
    };

    let cleanup: (() => void) | undefined;
    setupListener().then(fn => cleanup = fn);

    return () => {
      cleanup?.();
    };
  }, []);



  // Handle model config save
  const handleSaveModelConfig = async (config: ModelConfig) => {
    try {
      await invoke('api_save_model_config', {
        provider: config.provider,
        model: config.model,
        whisperModel: config.whisperModel,
        apiKey: config.apiKey,
        ollamaEndpoint: config.ollamaEndpoint,
      });

      setModelConfig(config);
      console.log('Model config saved successfully');
      setSettingsSaveSuccess(true);

      // Emit event to sync other components
      const { emit } = await import('@tauri-apps/api/event');
      await emit('model-config-updated', config);

      // Track settings change
      await Analytics.trackSettingsChanged('model_config', `${config.provider}_${config.model}`);
    } catch (error) {
      console.error('Error saving model config:', error);
      setSettingsSaveSuccess(false);
    }
  };

  const handleSaveTranscriptConfig = async (updatedConfig?: TranscriptModelProps) => {
    try {
      const configToSave = updatedConfig || transcriptModelConfig;
      const payload = {
        provider: configToSave.provider,
        model: configToSave.model,
        apiKey: configToSave.apiKey ?? null
      };
      console.log('Saving transcript config with payload:', payload);

      await invoke('api_save_transcript_config', {
        provider: payload.provider,
        model: payload.model,
        apiKey: payload.apiKey,
      });


      setSettingsSaveSuccess(true);

      // Track settings change
      const transcriptConfigToSave = updatedConfig || transcriptModelConfig;
      await Analytics.trackSettingsChanged('transcript_config', `${transcriptConfigToSave.provider}_${transcriptConfigToSave.model}`);
    } catch (error) {
      console.error('Failed to save transcript config:', error);
      setSettingsSaveSuccess(false);
    }
  };

  // Handle search input changes
  const handleSearchChange = useCallback(async (value: string) => {
    setSearchQuery(value);

    // If search query is empty, just return to normal view
    if (!value.trim()) return;

    // Search through transcripts
    await searchTranscripts(value);

    // Make sure the meetings folder is expanded when searching
    if (!expandedFolders.has('meetings')) {
      const newExpanded = new Set(expandedFolders);
      newExpanded.add('meetings');
      setExpandedFolders(newExpanded);
    }
  }, [expandedFolders, searchTranscripts]);

  // Combine search results with sidebar items
  const filteredSidebarItems = useMemo(() => {
    if (!searchQuery.trim()) return sidebarItems;

    // If we have search results, highlight matching meetings
    if (searchResults.length > 0) {
      // Get the IDs of meetings that matched in transcripts
      const matchedMeetingIds = new Set(searchResults.map(result => result.id));

      return sidebarItems
        .map(folder => {
          // Always include folders in the results
          if (folder.type === 'folder') {
            if (!folder.children) return folder;

            // Filter children based on search results or title match
            const filteredChildren = folder.children.filter(item => {
              // Include if the meeting ID is in our search results
              if (matchedMeetingIds.has(item.id)) return true;

              // Or if the title matches the search query
              return item.title.toLowerCase().includes(searchQuery.toLowerCase());
            });

            return {
              ...folder,
              children: filteredChildren
            };
          }

          // For non-folder items, check if they match the search
          return (matchedMeetingIds.has(folder.id) ||
            folder.title.toLowerCase().includes(searchQuery.toLowerCase()))
            ? folder : undefined;
        })
        .filter((item): item is SidebarItem => item !== undefined); // Type-safe filter
    } else {
      // Fall back to title-only filtering if no transcript results
      return sidebarItems
        .map(folder => {
          // Always include folders in the results
          if (folder.type === 'folder') {
            if (!folder.children) return folder;

            // Filter children based on search query
            const filteredChildren = folder.children.filter(item =>
              item.title.toLowerCase().includes(searchQuery.toLowerCase())
            );

            return {
              ...folder,
              children: filteredChildren
            };
          }

          // For non-folder items, check if they match the search
          return folder.title.toLowerCase().includes(searchQuery.toLowerCase()) ? folder : undefined;
        })
        .filter((item): item is SidebarItem => item !== undefined); // Type-safe filter
    }
  }, [sidebarItems, searchQuery, searchResults, expandedFolders]);


  const handleDelete = async (itemId: string) => {
    console.log('Deleting item:', itemId);
    const payload = {
      meetingId: itemId
    };

    try {
      const { invoke } = await import('@tauri-apps/api/core');
      await invoke('api_delete_meeting', {
        meetingId: itemId,
      });
      console.log('Meeting deleted successfully');
      const updatedMeetings = meetings.filter((m: CurrentMeeting) => m.id !== itemId);
      setMeetings(updatedMeetings);

      // Track meeting deletion
      Analytics.trackMeetingDeleted(itemId);

      // Show success toast
      toast.success("Meeting deleted successfully", {
        description: "All associated data has been removed"
      });

      // If deleting the active meeting, navigate to home
      if (currentMeeting?.id === itemId) {
        setCurrentMeeting({ id: 'intro-call', title: '+ New Call' });
        router.push('/');
      }
    } catch (error) {
      console.error('Failed to delete meeting:', error);
      toast.error("Failed to delete meeting", {
        description: error instanceof Error ? error.message : String(error)
      });
    }
  };

  const handleDeleteConfirm = () => {
    if (deleteModalState.itemId) {
      handleDelete(deleteModalState.itemId);
    }
    setDeleteModalState({ isOpen: false, itemId: null });
  };

  // Handle modal editing of meeting names
  const handleEditStart = (meetingId: string, currentTitle: string) => {
    setEditModalState({
      isOpen: true,
      meetingId: meetingId,
      currentTitle: currentTitle
    });
    setEditingTitle(currentTitle);
  };

  const handleEditConfirm = async () => {
    const newTitle = editingTitle.trim();
    const meetingId = editModalState.meetingId;

    if (!meetingId) return;

    // Prevent empty titles
    if (!newTitle) {
      toast.error("Meeting title cannot be empty");
      return;
    }

    try {
      await invoke('api_save_meeting_title', {
        meetingId: meetingId,
        title: newTitle,
      });

      // Update local state
      const updatedMeetings = meetings.map((m: CurrentMeeting) =>
        m.id === meetingId ? { ...m, title: newTitle } : m
      );
      setMeetings(updatedMeetings);

      // Update current meeting if it's the one being edited
      if (currentMeeting?.id === meetingId) {
        setCurrentMeeting({ id: meetingId, title: newTitle });
      }

      // Track the edit
      Analytics.trackButtonClick('edit_meeting_title', 'sidebar');

      toast.success("Meeting title updated successfully");

      // Close modal and reset state
      setEditModalState({ isOpen: false, meetingId: null, currentTitle: '' });
      setEditingTitle('');
    } catch (error) {
      console.error('Failed to update meeting title:', error);
      toast.error("Failed to update meeting title", {
        description: error instanceof Error ? error.message : String(error)
      });
    }
  };

  const handleEditCancel = () => {
    setEditModalState({ isOpen: false, meetingId: null, currentTitle: '' });
    setEditingTitle('');
  };

  const toggleFolder = (folderId: string) => {
    // Normal toggle behavior for all folders
    const newExpanded = new Set(expandedFolders);
    if (newExpanded.has(folderId)) {
      newExpanded.delete(folderId);
    } else {
      newExpanded.add(folderId);
    }
    setExpandedFolders(newExpanded);
  };

  // Expose setShowModelSettings to window for Rust tray to call
  useEffect(() => {
    (window as any).openSettings = () => {
      setShowModelSettings(true);
    };

    // Cleanup on unmount
    return () => {
      delete (window as any).openSettings;
    };
  }, []);

  const isHomePage = pathname === '/';
  const isMeetingPage = !!pathname?.includes('/meeting-details');
  const isSettingsPage = pathname === '/settings';

  // One row style for every nav destination; the active one gets the neutral pill.
  const navRow = (active: boolean) =>
    `w-full flex items-center gap-2.5 h-8 px-2.5 rounded-md text-sm transition-colors ${active ? 'bg-black/[0.07] text-gray-950 font-medium' : 'text-gray-700 hover:bg-black/[0.04] hover:text-gray-950'}`;
  const railButton = (active: boolean) =>
    `flex items-center justify-center w-10 h-10 rounded-md transition-colors ${active ? 'bg-black/[0.07] text-gray-950' : 'text-gray-600 hover:bg-black/[0.04] hover:text-gray-950'}`;

  const renderCollapsedIcons = () => {
    if (!isCollapsed) return null;

    const railItem = (label: string, active: boolean, onClick: () => void, icon: React.ReactNode) => (
      <Tooltip>
        <TooltipTrigger asChild>
          <button onClick={onClick} className={railButton(active)} aria-label={label}>{icon}</button>
        </TooltipTrigger>
        <TooltipContent side="right"><p>{label}</p></TooltipContent>
      </Tooltip>
    );

    return (
      <TooltipProvider>
        <div className="flex flex-col items-center gap-1 pt-4 h-full">
          <Logo isCollapsed={isCollapsed} />
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                onClick={handleRecordingToggle}
                disabled={isRecording}
                aria-label={isRecording ? 'Recording in progress' : 'Start recording'}
                className="flex items-center justify-center w-10 h-10 my-2 rounded-full bg-gray-950 text-white hover:bg-gray-800 disabled:bg-gray-950 disabled:cursor-not-allowed transition-colors"
              >
                <span className={`block w-2.5 h-2.5 rounded-full bg-red-500 ${isRecording ? 'animate-pulse' : ''}`} />
              </button>
            </TooltipTrigger>
            <TooltipContent side="right"><p>{isRecording ? 'Recording in progress' : 'Start recording'}</p></TooltipContent>
          </Tooltip>
          {railItem('Home', isHomePage, () => router.push('/'), <Home className="w-4 h-4" strokeWidth={1.75} />)}
          {railItem('Meetings', isMeetingPage, toggleCollapse, <NotebookPen className="w-4 h-4" strokeWidth={1.75} />)}
          {betaFeatures.importAndRetranscribe && railItem('Import audio', false, () => openImportDialog(), <Upload className="w-4 h-4" strokeWidth={1.75} />)}
          <div className="flex-1" />
          {railItem('Settings', isSettingsPage, () => router.push('/settings'), <Settings className="w-4 h-4" strokeWidth={1.75} />)}
          <Info isCollapsed={isCollapsed} />
          {railItem('Expand sidebar', false, toggleCollapse, <PanelLeftOpen className="w-4 h-4" strokeWidth={1.75} />)}
          <div className="h-3" />
        </div>
      </TooltipProvider>
    );
  };

  // Find matching transcript snippet for a meeting item
  const findMatchingSnippet = (itemId: string) => {
    if (!searchQuery.trim() || !searchResults.length) return null;
    return searchResults.find(result => result.id === itemId);
  };

  const renderItem = (item: SidebarItem, depth = 0) => {
    const isActive = item.type === 'file' && currentMeeting?.id === item.id;
    const isMeetingItem = item.id.includes('-') && !item.id.startsWith('intro-call');

    // Check if this item has a matching transcript snippet
    const matchingResult = isMeetingItem ? findMatchingSnippet(item.id) : null;
    const hasTranscriptMatch = !!matchingResult;

    if (isCollapsed || item.type === 'folder') return null;

    return (
      <div key={item.id}>
        <div
          className={`group flex flex-col rounded-md px-2.5 py-1.5 text-sm cursor-pointer transition-colors ${isActive ? 'bg-black/[0.07] text-gray-950 font-medium' : 'text-gray-700 hover:bg-black/[0.04] hover:text-gray-950'}`}
          onClick={() => {
            setCurrentMeeting({ id: item.id, title: item.title });
            const basePath = item.id.startsWith('intro-call') ? '/' :
              item.id.includes('-') ? `/meeting-details?id=${item.id}` : `/notes/${item.id}`;
            router.push(basePath);
          }}
        >
          <div className="flex items-center w-full min-h-5 gap-1">
            <span className="flex-1 min-w-0 truncate" title={item.title}>{item.title}</span>
            {isMeetingItem && (
              <div className="flex items-center opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity -my-1 -mr-1.5 has-[:focus-visible]:opacity-100">
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    handleEditStart(item.id, item.title);
                  }}
                  className="p-1 rounded text-gray-500 hover:text-gray-950 hover:bg-black/[0.06]"
                  aria-label="Rename meeting"
                >
                  <Pencil className="w-3.5 h-3.5" />
                </button>
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    setDeleteModalState({ isOpen: true, itemId: item.id });
                  }}
                  className="p-1 rounded text-gray-500 hover:text-red-700 hover:bg-red-50"
                  aria-label="Delete meeting"
                >
                  <Trash2 className="w-3.5 h-3.5" />
                </button>
              </div>
            )}
          </div>

          {/* Show transcript match snippet if available */}
          {hasTranscriptMatch && (
            <div className="mt-1 text-xs text-gray-600 font-normal line-clamp-2">
              {matchingResult.matchContext}
            </div>
          )}
        </div>
      </div>
    );
  };

  const meetingsFolder = filteredSidebarItems.find(item => item.id === 'meetings');
  const meetingCount = meetingsFolder?.children?.filter(c => c.id.includes('-') && !c.id.startsWith('intro-call')).length ?? 0;

  return (
    <div className="fixed top-0 left-0 h-screen z-40">
      <div
        className={`h-screen bg-[#f8f8f8] border-r border-gray-200 flex flex-col transition-[width] duration-200 ${isCollapsed ? 'w-16' : 'w-64'}`}
      >
        {isCollapsed ? renderCollapsedIcons() : (
          <>
            <div className="flex-shrink-0 px-3 pt-4">
              <div className="flex items-center justify-between pl-1 mb-4">
                <Logo isCollapsed={isCollapsed} />
                <button
                  onClick={toggleCollapse}
                  className="p-1.5 rounded-md text-gray-500 hover:text-gray-950 hover:bg-black/[0.05] transition-colors"
                  aria-label="Collapse sidebar"
                >
                  <PanelLeftClose className="w-4 h-4" strokeWidth={1.75} />
                </button>
              </div>

              <button
                onClick={handleRecordingToggle}
                disabled={isRecording}
                className="w-full flex items-center justify-center gap-2 h-9 rounded-md bg-gray-950 text-white text-sm font-medium hover:bg-gray-800 active:bg-black disabled:cursor-not-allowed transition-colors"
              >
                <span className={`block w-2 h-2 rounded-full bg-red-500 ${isRecording ? 'animate-pulse' : ''}`} />
                {isRecording ? 'Recording…' : 'Record a meeting'}
              </button>

              <div className="mt-3">
                <InputGroup className="bg-white">
                  <InputGroupInput placeholder="Search transcripts" aria-label="Search transcripts" value={searchQuery}
                    onChange={(e) => handleSearchChange(e.target.value)}
                  />
                  <InputGroupAddon>
                    <SearchIcon />
                  </InputGroupAddon>
                  {searchQuery &&
                    <InputGroupAddon align={'inline-end'}>
                      <InputGroupButton onClick={() => handleSearchChange('')} aria-label="Clear search">
                        <X />
                      </InputGroupButton>
                    </InputGroupAddon>
                  }
                </InputGroup>
              </div>

              <nav className="mt-3 flex flex-col gap-0.5">
                <button onClick={() => router.push('/')} className={navRow(isHomePage)}>
                  <Home className="w-4 h-4" strokeWidth={1.75} />
                  <span>Home</span>
                </button>
                {betaFeatures.importAndRetranscribe && (
                  <button onClick={() => openImportDialog()} className={navRow(false)}>
                    <Upload className="w-4 h-4" strokeWidth={1.75} />
                    <span>Import audio</span>
                  </button>
                )}
              </nav>

              <h2 className="flex items-center mt-6 mb-1 px-2.5 text-xs font-normal text-gray-600">
                <span>Meetings</span>
                <span className="ml-auto tabular-nums">
                  {searchQuery && isSearching ? 'Searching…' : meetingCount}
                </span>
              </h2>
            </div>

            <div className="flex-1 overflow-y-auto custom-scrollbar min-h-0 px-3">
              {meetingsFolder && expandedFolders.has('meetings') && (
                meetingCount === 0 ? (
                  <p className="px-2.5 py-1.5 text-sm text-gray-600">
                    {searchQuery ? 'No meetings match that search.' : 'Recorded meetings will appear here.'}
                  </p>
                ) : (
                  <div className="flex flex-col gap-0.5 pb-2">
                    {meetingsFolder.children!.map(child => renderItem(child, 1))}
                  </div>
                )
              )}
            </div>

            <div className="flex-shrink-0 px-3 pt-2 pb-3 border-t border-gray-200 flex flex-col gap-0.5">
              <button onClick={() => router.push('/settings')} className={navRow(isSettingsPage)}>
                <Settings className="w-4 h-4" strokeWidth={1.75} />
                <span>Settings</span>
              </button>
              <Info isCollapsed={isCollapsed} />
            </div>
          </>
        )}
      </div>

      {/* Confirmation Modal for Delete */}
      <ConfirmationModal
        isOpen={deleteModalState.isOpen}
        text="Are you sure you want to delete this meeting? This action cannot be undone."
        onConfirm={handleDeleteConfirm}
        onCancel={() => setDeleteModalState({ isOpen: false, itemId: null })}
      />

      {/* Edit Meeting Title Modal */}
      <Dialog open={editModalState.isOpen} onOpenChange={(open) => {
        if (!open) handleEditCancel();
      }}>
        <DialogContent className="sm:max-w-[425px]">
          <VisuallyHidden>
            <DialogTitle>Edit Meeting Title</DialogTitle>
          </VisuallyHidden>
          <div className="py-4">
            <h3 className="text-lg font-semibold mb-4">Edit Meeting Title</h3>
            <div className="space-y-4">
              <div>
                <label htmlFor="meeting-title" className="block text-sm font-medium text-gray-700 mb-2">
                  Meeting Title
                </label>
                <input
                  id="meeting-title"
                  type="text"
                  value={editingTitle}
                  onChange={(e) => setEditingTitle(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      handleEditConfirm();
                    } else if (e.key === 'Escape') {
                      handleEditCancel();
                    }
                  }}
                  className="w-full px-3 py-2 border border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:ring-ink-500 focus:border-transparent"
                  placeholder="Enter meeting title"
                  autoFocus
                />
              </div>
            </div>
          </div>
          <DialogFooter>
            <button
              onClick={handleEditCancel}
              className="px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 hover:bg-gray-200 rounded-md transition-colors"
            >
              Cancel
            </button>
            <button
              onClick={handleEditConfirm}
              className="px-4 py-2 text-sm font-medium text-white bg-ink-600 hover:bg-ink-700 rounded-md transition-colors"
            >
              Save
            </button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
};

export default Sidebar;
